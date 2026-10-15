import AppKit
import XCTest
import LunaCore
@testable import Luna

final class BlankEditorClickTests: XCTestCase {
    @MainActor func testSourceEditorCoversBlankSpaceBelowShortNote() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        workspace.toggleMarkdownPreview()
        workspace.editor.insertText("Last line", replacementRange: NSRange(location: 0, length: 0))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let clip = workspace.scroll.contentView
        let point = NSPoint(x: clip.bounds.midX, y: clip.bounds.maxY - 20)
        let hit = clip.hitTest(clip.convert(point, to: clip.superview))
        XCTAssertTrue(hit === workspace.editor, "The blank editor area must receive text clicks")
    }
}
