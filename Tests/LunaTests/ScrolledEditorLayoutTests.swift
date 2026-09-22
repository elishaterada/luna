import AppKit
import XCTest
import LunaCore
@testable import Luna

final class ScrolledEditorLayoutTests: XCTestCase {
    @MainActor func testSelectingWrappedListAfterScrollingKeepsLinePositions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let block = "• First item\n    • Second item\n        • Third item\n    • Fourth item that might be so long that it might wrap onto another line of text\n        • https://www.example.com/watch?value=long-enough-to-wrap\n            • Then next\n\n"
        let note = Note(text: String(repeating: block, count: 4), language: "Markdown")
        workspace.notes.append(note); workspace.reloadShelf(); workspace.select(note.id)
        workspace.showWindow(nil)
        workspace.window?.setContentSize(NSSize(width: 1000, height: 700))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let editor = workspace.editor
        let target = (block as NSString).length
        workspace.scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        workspace.scroll.reflectScrolledClipView(workspace.scroll.contentView)
        try await Task.sleep(nanoseconds: 200_000_000)
        let source = editor.string as NSString
        let selectedLine = source.range(of: "    • Fourth", options: [], range: NSRange(location: target, length: source.length - target)).location
        let nextLine = source.range(of: "        • https", options: [], range: NSRange(location: selectedLine, length: source.length - selectedLine)).location
        let selectedBefore = editor.firstRect(forCharacterRange: NSRange(location: selectedLine + 12, length: 1), actualRange: nil)
        let before = editor.firstRect(forCharacterRange: NSRange(location: nextLine, length: 1), actualRange: nil)
        XCTAssertGreaterThan(workspace.scroll.contentView.bounds.minY, 0)
        let window = try XCTUnwrap(workspace.window)
        let clickRect = editor.firstRect(forCharacterRange: NSRange(location: selectedLine + 12, length: 1), actualRange: nil)
        let point = window.convertPoint(fromScreen: NSPoint(x: clickRect.midX, y: clickRect.midY))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 3, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 3, pressure: 1))
        NSApp.postEvent(up, atStart: true)
        editor.mouseDown(with: down)
        XCTAssertEqual(editor.selectedRange(), source.lineRange(for: NSRange(location: selectedLine, length: 0)))
        for _ in 0..<4 {
            let attributesBefore = NSAttributedString(attributedString: try XCTUnwrap(editor.textStorage))
            workspace.highlighter.highlight(editor)
            XCTAssertEqual(editor.textStorage, attributesBefore, "Viewport highlighting must not rewrite paragraph or document attributes")
            try await Task.sleep(nanoseconds: 80_000_000)
            let selectedAfter = editor.firstRect(forCharacterRange: NSRange(location: selectedLine + 12, length: 1), actualRange: nil)
            XCTAssertEqual(selectedAfter.minY, selectedBefore.minY, accuracy: 1, "Selected line must retain its position")
            let after = editor.firstRect(forCharacterRange: NSRange(location: nextLine, length: 1), actualRange: nil)
            XCTAssertEqual(after.minY, before.minY, accuracy: 1, "Selecting a scrolled list must not move the next line")
        }
        XCTAssertEqual(editor.string, note.text)
    }
}
