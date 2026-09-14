import AppKit
import XCTest
import LunaCore
@testable import Luna

final class BlankEditorClickTests: XCTestCase {
    @MainActor func testBlankSpaceBelowLiveNoteMovesCaretToLastLine() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let note = Note(text: "First\n[Example](https://example.com)\nLast line")
        try store.save(note)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof source")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let atEnd = try await view.evaluateJavaScript("""
        const first=document.querySelector('.text');first.focus();
        const initial=document.createRange();initial.selectNodeContents(first);initial.collapse(true);
        getSelection().removeAllRanges();getSelection().addRange(initial);
        const last=document.querySelector('.text:last-child');
        document.body.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,button:0,clientX:100,clientY:last.getBoundingClientRect().bottom+30}));
        const end=document.createRange();end.selectNodeContents(last);end.collapse(false);
        document.activeElement===last && getSelection().isCollapsed && getSelection().getRangeAt(0).compareBoundaryPoints(Range.START_TO_START,end)===0;
        """) as? Bool
        XCTAssertEqual(atEnd, true)
        let source = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(source, note.text, "Clicking whitespace must not insert new lines")
        _ = try await view.evaluateJavaScript("document.execCommand('insertText',false,'!')")
        let edited = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(edited, note.text + "!", "Typing after the click must append to the last line")
    }
    @MainActor func testRegularEditorCoversBlankSpaceBelowShortNote() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        workspace.editor.insertText("Last line", replacementRange: NSRange(location: 0, length: 0))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let clip = workspace.scroll.contentView
        let point = NSPoint(x: clip.bounds.midX, y: clip.bounds.maxY - 20)
        let hit = clip.hitTest(clip.convert(point, to: clip.superview))
        XCTAssertTrue(hit === workspace.editor, "The blank editor area must receive text clicks")
    }
}
