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
