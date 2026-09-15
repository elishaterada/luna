import AppKit
import XCTest
import LunaCore
@testable import Luna

final class FileDropTests: XCTestCase {
    @MainActor func testPasteboardAcceptsMultipleFilesRegardlessOfExtension() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/notes.md"), URL(fileURLWithPath: "/tmp/.env"),
                    URL(fileURLWithPath: "/tmp/custom.unusual")]
        pasteboard.writeObjects(urls as [NSURL])
        XCTAssertEqual(FileDrop.urls(in: pasteboard), urls)
        pasteboard.clearContents()
        pasteboard.setString("ordinary dragged text", forType: .string)
        XCTAssertTrue(FileDrop.urls(in: pasteboard).isEmpty)
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(string: "https://example.com")!])
        XCTAssertTrue(FileDrop.urls(in: pasteboard).isEmpty)
    }

    @MainActor func testDropOpensFilesAndPreservesCurrentNote() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = Workspace(store: store,
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let original = try XCTUnwrap(workspace.selectedID)
        workspace.editor.string = "Keep my unsaved note"
        workspace.textDidChange(Notification(name: NSText.didChangeNotification))
        let first = root.appendingPathComponent("custom.unusual")
        let second = root.appendingPathComponent(".env")
        try "First file".write(to: first, atomically: true, encoding: .utf8)
        try "SECOND=value".write(to: second, atomically: true, encoding: .utf8)
        workspace.editor.onFileDrop?([first, second])
        for _ in 0..<200 {
            if workspace.notes.count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(workspace.notes.count, 3)
        XCTAssertEqual(workspace.notes.first(where: { $0.id == original })?.text, "Keep my unsaved note")
        XCTAssertEqual(workspace.notes.first(where: { $0.path == first.path })?.text, "First file")
        XCTAssertTrue(workspace.notes.allSatisfy { $0.media.isEmpty })
        workspace.mediaView.onFileDrop?([first])
        XCTAssertEqual(workspace.notes.count, 3)
        XCTAssertEqual(workspace.notes.first(where: { $0.id == workspace.selectedID })?.path, first.path)
        workspace.markdownPreview.onFileDrop?([second])
        XCTAssertEqual(workspace.notes.first(where: { $0.id == workspace.selectedID })?.path, second.path)
        let dropRoot = try XCTUnwrap(workspace.window?.contentView as? FileDropView)
        dropRoot.onFileDrop?([first])
        XCTAssertEqual(workspace.notes.first(where: { $0.id == workspace.selectedID })?.path, first.path)
        XCTAssertTrue(workspace.table.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(workspace.flushAllRecovery())
        XCTAssertEqual(try store.load().first(where: { $0.id == original })?.text, "Keep my unsaved note")
    }
}
