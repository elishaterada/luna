import AppKit
import WebKit
import XCTest
import LunaCore
@testable import Luna

final class PlainTextPasteTests: XCTestCase {
    @MainActor private func workspace(_ text: String, language: String = "Markdown") throws -> Workspace {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: text, language: language))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        workspace.showWindow(nil)
        addTeardownBlock { @MainActor in workspace.close(); try? FileManager.default.removeItem(at: root) }
        return workspace
    }

    @MainActor private func clipboard(_ text: String) {
        let board = NSPasteboard.general
        let previous = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        addTeardownBlock { @MainActor in
            board.clearContents()
            let items = previous.map { values in
                let item = NSPasteboardItem()
                values.forEach { item.setData($0.1, forType: $0.0) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("<b>Rich clipboard content</b>", forType: .html)
    }

    @MainActor private func pasteShortcut(_ workspace: Workspace) throws {
        let delegate = AppDelegate()
        delegate.workspace = workspace
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        delegate.buildMenu()
        let edit = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu)
        let item = try XCTUnwrap(edit.item(withTitle: "Paste as Plain Text"))
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        edit.removeItem(item)
        let menu = NSMenu()
        menu.addItem(item)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: workspace.window!.windowNumber, context: nil, characters: "V",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
    }

    @MainActor private func waitForSource(_ expected: String, in view: MediaNoteView) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("source()")) as? String == expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let actual = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(actual, expected)
    }

    @MainActor func testShortcutReplacesNativeSelectionWithPlainClipboardAndUndo() throws {
        clipboard("https://example.com\n🌙 <iframe>literal</iframe>")
        for language in ["Plain Text", "Markdown", "Swift"] {
            let workspace = try workspace("Before selected after", language: language)
            if workspace.richEditing { workspace.toggleMarkdownPreview() }
            let editor = workspace.editor
            workspace.window?.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 7, length: 8))
            let undo = try XCTUnwrap(editor.undoManager)
            undo.beginUndoGrouping()
            try pasteShortcut(workspace)
            undo.endUndoGrouping()
            XCTAssertEqual(editor.string, "Before https://example.com\n🌙 <iframe>literal</iframe> after")
            XCTAssertFalse(workspace.richEditing)
            undo.undo()
            XCTAssertEqual(editor.string, "Before selected after")
        }
    }

}
