import AppKit
import XCTest
import LunaCore
@testable import Luna

final class NoteNavigationTests: XCTestCase {
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
