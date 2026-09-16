import AppKit
import XCTest
import LunaCore
@testable import Luna

final class NoteNavigationTests: XCTestCase {
    @MainActor func testNumberShortcutsFollowShelfOrderAndPreserveEdits() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = Workspace(store: store,
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.newNote()
        let editedID = try XCTUnwrap(workspace.selectedID)
        workspace.editor.string = "Keep this unsaved note"
        workspace.textDidChange(Notification(name: NSText.didChangeNotification))
        let target = workspace.notes[1].id
        let window = try XCTUnwrap(workspace.window as? NoteShortcutWindow)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "2",
            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(workspace.selectedID, target)
        XCTAssertEqual(try store.load().first(where: { $0.id == editedID })?.text, "Keep this unsaved note")
        workspace.togglePin(target)
        XCTAssertTrue(workspace.selectNote(number: 1))
        XCTAssertEqual(workspace.selectedID, target)
        XCTAssertFalse(workspace.selectNote(number: 9))
        XCTAssertFalse(workspace.selectNote(number: 0))
        workspace.table.showsShortcutHints = true
        let cell = try XCTUnwrap(workspace.tableView(workspace.table, viewFor: nil, row: 0) as? NoteCellView)
        XCTAssertEqual(cell.shortcutLabel.stringValue, "⌘1")
        XCTAssertFalse(cell.shortcutLabel.isHidden)
        XCTAssertTrue(cell.actionsButton.isHidden)
        window.resetShortcutHints()
        XCTAssertFalse(workspace.table.showsShortcutHints)
    }

    @MainActor func testNoteActionsExposeShortcutsAndCleanFilesCloseWithoutConfirmation() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }

        let menu = workspace.makeNoteActionsMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Pin", "Duplicate", "Share…", "Open in New Window", "Delete Note…"])
        XCTAssertEqual(menu.items.map(\.keyEquivalent), ["p", "d", "s", "o", "\u{8}"])
        XCTAssertEqual(menu.items.map(\.keyEquivalentModifierMask), [
            [.command, .control], .command, [.command, .control], [.command, .shift], .command
        ])

        var cleanFile = Note(text: "Saved", path: root.appendingPathComponent("saved.md").path)
        cleanFile.dirty = false
        XCTAssertFalse(Workspace.requiresCloseConfirmation(cleanFile))
        cleanFile.dirty = true
        XCTAssertTrue(Workspace.requiresCloseConfirmation(cleanFile))
        XCTAssertTrue(Workspace.requiresCloseConfirmation(Note(text: "Private")))
    }

    @MainActor func testPinsDuplicatesAndSharedWindows() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = Workspace(store: store,
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let original = try XCTUnwrap(workspace.selectedID)
        workspace.editor.string = "Original"
        workspace.textDidChange(Notification(name: NSText.didChangeNotification))
        workspace.newNote()
        workspace.togglePin(original)
        XCTAssertEqual(workspace.notes.first?.id, original)
        XCTAssertTrue(try XCTUnwrap(store.load().first(where: { $0.id == original })).isPinned)
        workspace.duplicateNote(original)
        let copy = try XCTUnwrap(workspace.selectedID)
        XCTAssertNotEqual(copy, original)
        XCTAssertEqual(workspace.editor.string, "Original")
        XCTAssertNil(workspace.notes.first(where: { $0.id == copy })?.path)
        let child = try XCTUnwrap(workspace.openNoteInWindow(copy))
        defer { child.close() }
        child.window?.makeKeyAndOrderFront(nil)
        // XCTest has no active application/key window; verify the native responder chain directly.
        XCTAssertTrue(child.window?.nextResponder === child)
        XCTAssertTrue(child.responds(to: #selector(Workspace.save)))
        XCTAssertTrue(child.responds(to: #selector(Workspace.deleteNote)))
        child.editor.string = "Changed in another window"
        child.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertEqual(workspace.editor.string, "Changed in another window")
        XCTAssertEqual(workspace.notes.first(where: { $0.id == original })?.text, "Original")
        XCTAssertTrue(workspace.flushAllRecovery())
        XCTAssertEqual(try store.load().first(where: { $0.id == copy })?.text, "Changed in another window")
        XCTAssertTrue(child.removeNote(copy))
        XCTAssertFalse(workspace.notes.contains(where: { $0.id == copy }))
        XCTAssertNotEqual(workspace.selectedID, copy)
        XCTAssertEqual(workspace.editor.string, workspace.notes.first(where: { $0.id == workspace.selectedID })?.text)
    }
    @MainActor func testReorderingAndDeletingPreserveSelectionAndRecovery() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = Workspace(store: store,
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let initialID = try XCTUnwrap(workspace.selectedID)
        // A brand-new note may not yet have a recovery file.
        XCTAssertTrue(workspace.removeNote(initialID))
        let first = try XCTUnwrap(workspace.selectedID)
        workspace.newNote()
        let second = try XCTUnwrap(workspace.selectedID)
        workspace.newNote()
        let third = try XCTUnwrap(workspace.selectedID)
        workspace.editor.string = "Keep this edit"
        workspace.textDidChange(Notification(name: NSText.didChangeNotification))
        workspace.editor.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(workspace.moveNote(third, to: 3))
        XCTAssertEqual(workspace.notes.map(\.id), [second, first, third])
        XCTAssertEqual(workspace.selectedID, third)
        XCTAssertEqual(workspace.editor.selectedRange().location, 4)
        XCTAssertTrue(workspace.moveNote(first, to: 0))
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().map(\.id), [first, second, third])
        XCTAssertTrue(workspace.removeNote(second))
        XCTAssertEqual(workspace.selectedID, third)
        XCTAssertEqual(workspace.editor.string, "Keep this edit")
        XCTAssertTrue(workspace.removeNote(third))
        XCTAssertEqual(workspace.selectedID, first)
        XCTAssertTrue(workspace.removeNote(first))
        XCTAssertEqual(workspace.notes.count, 1)
        XCTAssertEqual(workspace.editor.string, "")
        XCTAssertEqual(try store.load().map(\.id), workspace.notes.map(\.id))
    }
    @MainActor func testArrowNavigationKeepsListFocusUntilRightArrow() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.notes = [Note(text: "First\nline"), Note(text: "Second\nline"), Note(text: "Third\nline")]
        workspace.reloadShelf(); workspace.select(workspace.notes[0].id)
        let window = try XCTUnwrap(workspace.window)
        workspace.showWindow(nil)
        XCTAssertTrue(window.firstResponder === workspace.table)

        func arrow(_ keyCode: UInt16, _ character: UnicodeScalar) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
        try arrow(125, UnicodeScalar(NSDownArrowFunctionKey)!)
        XCTAssertEqual(workspace.selectedID, workspace.notes[1].id)
        XCTAssertEqual(workspace.editor.string, "Second\nline")
        XCTAssertTrue(window.firstResponder === workspace.table)
        try arrow(125, UnicodeScalar(NSDownArrowFunctionKey)!)
        XCTAssertEqual(workspace.selectedID, workspace.notes[2].id)
        try arrow(126, UnicodeScalar(NSUpArrowFunctionKey)!)
        XCTAssertEqual(workspace.selectedID, workspace.notes[1].id)
        XCTAssertTrue(window.firstResponder === workspace.table)

        try arrow(124, UnicodeScalar(NSRightArrowFunctionKey)!)
        XCTAssertTrue(window.firstResponder === workspace.editor)
        XCTAssertEqual(workspace.editor.selectedRange().location, 0)
        try arrow(125, UnicodeScalar(NSDownArrowFunctionKey)!)
        XCTAssertEqual(workspace.selectedID, workspace.notes[1].id)
        XCTAssertGreaterThan(workspace.editor.selectedRange().location, 0)

        // Returning to the shelf restores file navigation; creating a note is an explicit edit action.
        window.makeFirstResponder(workspace.table)
        workspace.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(window.firstResponder === workspace.table)
        try arrow(125, UnicodeScalar(NSDownArrowFunctionKey)!)
        XCTAssertEqual(workspace.selectedID, workspace.notes[1].id)
        workspace.toggleSidebar()
        XCTAssertTrue(window.firstResponder === workspace.editor)
        workspace.newNote()
        XCTAssertTrue(window.firstResponder === workspace.editor)
    }
}
