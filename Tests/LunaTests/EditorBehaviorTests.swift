import AppKit
import XCTest
import LunaCore
@testable import Luna

final class EditorBehaviorTests: XCTestCase {
    private func preference(_ key: String, _ value: Any) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.set(value, forKey: key)
        addTeardownBlock {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    @MainActor func testIndentationCanBeContinuedOrDisabled() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        preference("editor.autoIndent", true)
        editor.string = "  hello"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "  hello\n  ")
        preference("editor.autoIndent", false)
        editor.string = "  hello"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "  hello\n")
    }
    @MainActor func testTabInsertionRespectsSpacesAndLiteralTabs() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  ")
        preference("editor.useTabs", true)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  \t")
    }
    @MainActor func testPresentationZoomIsVisibleAndPreservesNormalSize() throws {
        _ = NSApplication.shared
        preference("editor.fontSize", 18.0)
        preference("editor.presentationSize", 26.0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        workspace.togglePresentation()
        XCTAssertEqual(workspace.editor.font?.pointSize, 26)
        workspace.larger()
        XCTAssertEqual(workspace.editor.font?.pointSize, 28)
        workspace.smaller(); workspace.smaller()
        XCTAssertEqual(workspace.editor.font?.pointSize, 26)
        workspace.togglePresentation()
        XCTAssertEqual(workspace.editor.font?.pointSize, 18)
        XCTAssertEqual(EditorPreferences.fontSize, 18)
        workspace.close()
    }
    @MainActor func testInvalidNumericPreferencesHaveSafeBounds() {
        preference("editor.padding", -20.0)
        preference("editor.presentationSize", 100.0)
        preference("editor.lineSpacing", Double.nan)
        XCTAssertEqual(EditorPreferences.editorPadding, 16)
        XCTAssertEqual(EditorPreferences.presentationSize, 60)
        XCTAssertEqual(EditorPreferences.lineSpacing, 0.3)
    }
}

extension EditorBehaviorTests {
    @MainActor func testListsFormatContinueExitAndKeepCodeLiteral() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        editor.insertText("- ", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "• ")
        editor.insertText("[ ] Task", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "☐ Task")
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n☐ ")
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n")
        editor.insertText("3) Third", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n3. Third\n4. ")
        editor.formatsLists = false
        editor.string = ""; editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("- literal", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "- literal")
        XCTAssertEqual(NoteLists.formatted("- [x] Done\n* Item\n```\n- code\n```"), "☑ Done\n• Item\n```\n- code\n```")
    }
    @MainActor func testLiveListEditingAndVisibleMetadata() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        var note = Note(text: "Start\n[Preview](https://example.com)", path: root.appendingPathComponent("note.txt").path)
        note.dirty = true
        try store.save(note)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        XCTAssertTrue(workspace.updated.stringValue.hasPrefix("Updated "))
        XCTAssertFalse(workspace.notePath.isHidden)
        XCTAssertTrue(workspace.subtitle.isHidden)
        XCTAssertEqual(NotePathView.segments(for: note.path!).dropLast().last?.url?.path, root.path)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await view.evaluateJavaScript("const block=document.querySelector('.text');block.innerText='';block.focus();document.execCommand('insertText',false,'- [ ] Task');")
        _ = try await view.callAsyncJavaScript("resolvePreview(0, title)", arguments: ["title": "A page title <safe>"], in: nil, contentWorld: .page)
        let previewTitle = try await view.evaluateJavaScript("document.querySelector('[data-preview]').textContent") as? String
        XCTAssertEqual(previewTitle, "A page title <safe> ↗")
        let text = try await view.evaluateJavaScript("document.querySelector('.text').innerText") as? String
        XCTAssertEqual(text, "☐ Task")
        _ = try await view.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));")
        let source = try await view.evaluateJavaScript("source()") as? String
        XCTAssertTrue(source?.hasPrefix("☐ Task\n☐ ") == true)
    }
    func testURLPasteChoicesHaveDistinctPersistentRendering() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))
        XCTAssertFalse(NoteEmbeds.hasContent(URLPasteChoice.plain.snippet(for: url)))
        for choice in [URLPasteChoice.linked, .preview, .embed] {
            let source = choice.snippet(for: url)
            XCTAssertTrue(NoteEmbeds.hasContent(source))
            XCTAssertEqual(NoteEmbeds.blocks(source).map(\.source).joined(separator: "\n"), source)
            let html = MediaNoteView.page(Note(text: source), fontSize: 18, dark: true, pageID: "test")
            XCTAssertEqual(html.contains("<iframe data-embed="), choice == .embed)
            if choice == .preview { XCTAssertTrue(html.contains("class=\"link-chip\"")) }
            if choice == .linked { XCTAssertTrue(html.contains("class=\"linked-text\"")) }
        }
    }
}
