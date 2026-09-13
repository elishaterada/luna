import AppKit
import WebKit
import XCTest
import LunaCore
@testable import Luna

final class NoteEmbedsTests: XCTestCase {
    func testEmbedParsingEscapesScriptsAndRespectsCodeBlocks() throws {
        let snippet = try XCTUnwrap(NoteEmbeds.insertion("<iframe src='https://example.com/embed?a=1&amp;b=2' onload='bad()'></iframe>"))
        XCTAssertEqual(snippet, "\n[Embed](https://example.com/embed?a=1&b=2)\n")
        XCTAssertNil(NoteEmbeds.insertion("<iframe src='javascript:alert(1)'></iframe>"))
        XCTAssertNil(NoteEmbeds.insertion("file:///private/secret"))
        XCTAssertFalse(NoteEmbeds.hasContent("```html\nhttps://example.com\n```"))
        let source = "Before\n\n" + snippet + "\nAfter"
        XCTAssertEqual(NoteEmbeds.blocks(source).map(\.source).joined(separator: "\n"), source)
        let page = MediaNoteView.page(Note(text: source + "\n<script>bad()</script>"), fontSize: 18, dark: true, pageID: "test")
        XCTAssertTrue(page.contains("sandbox=\"allow-scripts allow-same-origin allow-presentation\""))
        XCTAssertFalse(page.contains("<script>bad()"))
        XCTAssertTrue(page.contains("&lt;script&gt;bad()&lt;/script&gt;"))
        XCTAssertTrue(page.contains("contenteditable=\"plaintext-only\""))
    }
    func testOEmbedUsesOnlySafeProviderURLs() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "video", "html": "<iframe src=\"https://player.example.com/123\" onload=\"bad()\"></iframe><script>bad()</script>"])
        XCTAssertEqual(EmbedResolver.responseURL(data)?.absoluteString, "https://player.example.com/123")
        XCTAssertNil(EmbedResolver.responseURL(try JSONSerialization.data(withJSONObject: ["type": "video", "html": "<script>bad()</script>"])))
    }
    @MainActor func testDropsEnterLiveViewAndCanAddAnotherAttachment() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "skin", withExtension: "mp4", subdirectory: "Fixtures"))
        workspace.editor.insertText("Before After", replacementRange: NSRange(location: 0, length: 0))
        workspace.importMedia([file], range: NSRange(location: 7, length: 0))
        for _ in 0..<100 {
            if workspace.richEditing, ((try? await workspace.mediaView.evaluateJavaScript("document.querySelectorAll('video').length")) as? Int) == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(workspace.richEditing)
        XCTAssertTrue(workspace.editor.string.hasPrefix("Before "))
        XCTAssertTrue(workspace.editor.string.hasSuffix("After"))
        workspace.importMedia([file])
        var renderedCount = 0
        for _ in 0..<100 {
            renderedCount = ((try? await workspace.mediaView.evaluateJavaScript("document.querySelectorAll('video').length")) as? Int) ?? 0
            if renderedCount == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(renderedCount, 2)
        XCTAssertEqual(workspace.notes[workspace.index!].media.count, 2)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try workspace.store.load().first?.text, workspace.editor.string)
    }
    @MainActor func testLiveViewEditsRoundTripAndMediaActuallyLoads() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let file = root.appendingPathComponent("pixel.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!.write(to: file)
        var note = Note(text: "Before\n")
        let video = try XCTUnwrap(Bundle.module.url(forResource: "skin", withExtension: "mp4", subdirectory: "Fixtures"))
        note.attachments = try store.importMedia([file, video], noteID: note.id)
        note.text += "![pixel](\(note.media[0].reference))\n![video](\(note.media[1].reference))\nAfter"
        try store.save(note)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        XCTAssertTrue(workspace.richEditing)
        let view = workspace.mediaView
        var loaded = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('img')?.naturalWidth")) as? Int == 1 { loaded = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(loaded, "Imported image must load through the note-scoped media handler")
        var videoReady = false
        for _ in 0..<100 {
            if ((try? await view.evaluateJavaScript("document.querySelector('video')?.readyState")) as? Int ?? 0) > 0 { videoReady = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(videoReady, "Video player must load media metadata")
        _ = try await view.callAsyncJavaScript("const video=document.querySelector('video');video.muted=true;await video.play();", arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: 200_000_000)
        let playbackTime = try await view.evaluateJavaScript("document.querySelector('video').currentTime") as? Double
        XCTAssertGreaterThan(playbackTime ?? 0, 0)
        _ = try await view.evaluateJavaScript("document.querySelector('video').pause()")
        let renderedSource = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(renderedSource, note.text)
        _ = try await view.evaluateJavaScript("document.querySelector('.text').innerText='Changed';post('input')")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(workspace.editor.string.hasPrefix("Changed"))
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().first?.text, workspace.editor.string)
        workspace.toggleMarkdownPreview()
        XCTAssertFalse(workspace.richEditing)
        XCTAssertFalse(workspace.scroll.isHidden)
        workspace.toggleMarkdownPreview()
        XCTAssertTrue(workspace.richEditing)
    }
}
