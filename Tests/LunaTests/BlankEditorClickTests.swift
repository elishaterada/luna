import AppKit
import XCTest
import LunaCore
@testable import Luna

final class BlankEditorClickTests: XCTestCase {
    @MainActor private func liveWorkspace(_ text: String) async throws -> Workspace {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: text, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        addTeardownBlock { @MainActor in workspace.close(); try? FileManager.default.removeItem(at: root) }
        workspace.showWindow(nil)
        for _ in 0..<100 {
            if (try? await workspace.mediaView.evaluateJavaScript("typeof source")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return workspace
    }

    @MainActor private func clickBelowText(_ workspace: Workspace) async throws {
        let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
        _ = try await view.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const start=document.createRange();start.selectNodeContents(block.firstChild);start.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(start);
            """, in: nil, contentWorld: .page)
        let point = view.convert(NSPoint(x: 100, y: view.bounds.height - 30), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0))
            if kind == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    @MainActor private func typeKey(_ text: String, keyCode: UInt16, in workspace: Workspace) async throws {
        let window = try XCTUnwrap(workspace.window)
        window.makeFirstResponder(workspace.mediaView)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode)))
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    @MainActor func testNativeBlankClickBelowLoadedWrappedList() async throws {
        let original = "Help\n- Build a large Safari Park Zoo\n- Build a natural history museum\n- Build a art museum featuring real art from sculpture to paintings that are legal to display"
        let workspace = try await liveWorkspace(original)
        _ = try await workspace.mediaView.evaluateJavaScript("document.querySelector('.text').style.width='400px'")
        try await clickBelowText(workspace)
        let result = try await workspace.mediaView.callAsyncJavaScript("""
            updateTextCaret();const visible=!document.getElementById('text-caret').hidden;
            const unchanged=source();document.execCommand('insertText',false,'!');
            return [visible,unchanged,source()];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? String, original)
        XCTAssertEqual(result?[2] as? String, original + "!")
    }

    @MainActor func testNativeBlankClickBelowNewlyTypedParagraph() async throws {
        let workspace = try await liveWorkspace("Before")
        let view = workspace.mediaView
        _ = try await view.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const end=document.createRange();end.selectNodeContents(block);end.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(end);
            """, in: nil, contentWorld: .page)
        try await typeKey("\r", keyCode: 36, in: workspace)
        for (text, code) in [("T", UInt16(17)), ("a", 0), ("i", 34), ("l", 37)] {
            try await typeKey(text, keyCode: code, in: workspace)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try await clickBelowText(workspace)
        let result = try await view.callAsyncJavaScript("""
            updateTextCaret();const visible=!document.getElementById('text-caret').hidden;
            const unchanged=source(),html=document.querySelector('.text').innerHTML;
            const row=document.querySelector('.text').lastElementChild,text=row.firstChild;
            const glyph=document.createRange();glyph.setStart(text,text.length-1);glyph.setEnd(text,text.length);
            const expected=glyph.getBoundingClientRect(),caret=document.getElementById('text-caret').getBoundingClientRect();
            return [visible,unchanged,html,caret.left,expected.right,caret.top,expected.top+(expected.height-18)/2];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true, "Click below typed text must show the EOL caret: \(result ?? [])")
        XCTAssertEqual(result?[1] as? String, "Before\nTail")
        XCTAssertEqual(try XCTUnwrap(result?[3] as? Double), try XCTUnwrap(result?[4] as? Double), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(result?[5] as? Double), try XCTUnwrap(result?[6] as? Double), accuracy: 1)
        try await typeKey("!", keyCode: 18, in: workspace)
        try await Task.sleep(nanoseconds: 100_000_000)
        let edited = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(edited, "Before\nTail!")
    }

    @MainActor func testNativeBlankClickBelowContinuedListAppendsToLastItem() async throws {
        let workspace = try await liveWorkspace("")
        workspace.focusContent()
        try await Task.sleep(nanoseconds: 100_000_000)
        for character in "Help" { try await typeKey(String(character), keyCode: 0, in: workspace) }
        try await typeKey("\r", keyCode: 36, in: workspace)
        for character in "- A" { try await typeKey(String(character), keyCode: 0, in: workspace) }
        try await typeKey("\r", keyCode: 36, in: workspace)
        try await typeKey("B", keyCode: 11, in: workspace)
        try await typeKey("\r", keyCode: 36, in: workspace)
        for character in "Build a art museum featuring real art from sculpture to paintings that are legal to display" {
            try await typeKey(String(character), keyCode: 0, in: workspace)
        }
        let original = "Help\n- A\n- B\n- Build a art museum featuring real art from sculpture to paintings that are legal to display"
        let unchanged = try await workspace.mediaView.evaluateJavaScript("source()") as? String
        XCTAssertEqual(unchanged, original)
        try await clickBelowText(workspace)
        let caret = try await workspace.mediaView.callAsyncJavaScript("""
            updateTextCaret();return [!document.getElementById('text-caret').hidden,source()];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(caret?[0] as? Bool, true)
        XCTAssertEqual(caret?[1] as? String, original)
        try await typeKey("!", keyCode: 18, in: workspace)
        let edited = try await workspace.mediaView.evaluateJavaScript("source()") as? String
        XCTAssertEqual(edited, original + "!", "Blank click must append inside the final list item")
    }

    @MainActor func testBlankClickCaretAfterStyledTextAndEmptyParagraphs() async throws {
        for empty in [false, true] {
            let workspace = try await liveWorkspace("Before")
            let result = try await workspace.mediaView.callAsyncJavaScript("""
                const block=document.querySelector('.text');block.focus();
                const end=document.createRange();end.selectNodeContents(block);end.collapse(false);
                getSelection().removeAllRanges();getSelection().addRange(end);
                document.execCommand('insertParagraph');
                if(empty){document.execCommand('insertParagraph');document.execCommand('insertParagraph');}
                else{document.execCommand('bold');document.execCommand('insertText',false,'Tail');}
                return source();
                """, arguments: ["empty": empty], in: nil, contentWorld: .page) as? String
            try await clickBelowText(workspace)
            let caret = try await workspace.mediaView.callAsyncJavaScript("""
                const selection=getSelection(),saved=selection.getRangeAt(0).cloneRange();updateTextCaret();
                const row=document.querySelector('.text').lastElementChild,indicator=document.getElementById('text-caret');
                const bounds=row.getBoundingClientRect(),actual=indicator.getBoundingClientRect(),style=getComputedStyle(row);
                return [!indicator.hidden,source(),saved.compareBoundaryPoints(Range.START_TO_START,selection.getRangeAt(0))===0,
                  actual.top,bounds.top+(parseFloat(style.lineHeight)-parseFloat(style.fontSize))/2];
                """, in: nil, contentWorld: .page) as? [Any]
            XCTAssertEqual(caret?[0] as? Bool, true, "EOL caret must be visible for empty=\(empty)")
            XCTAssertEqual(caret?[1] as? String, result)
            XCTAssertEqual(caret?[2] as? Bool, true, "Geometry must not move the editing selection")
            XCTAssertEqual(try XCTUnwrap(caret?[3] as? Double), try XCTUnwrap(caret?[4] as? Double), accuracy: 2)
        }
    }
    @MainActor func testBlankSpaceBelowLiveNoteMovesCaretToLastLine() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let note = Note(text: "First\n[Example](https://example.com)\nLast line", language: "Markdown")
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
