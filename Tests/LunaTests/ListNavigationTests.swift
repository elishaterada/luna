import AppKit
import XCTest
import LunaCore
@testable import Luna

final class ListNavigationTests: XCTestCase {
    @MainActor private func workspace(_ text: String) async throws -> Workspace {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecoveryStore(directory: root)
        try store.save(Note(text: text, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        addTeardownBlock { @MainActor in workspace.close(); try? FileManager.default.removeItem(at: root) }
        workspace.showWindow(nil)
        for _ in 0..<100 {
            if (try? await workspace.mediaView.evaluateJavaScript("typeof currentLine")) as? String == "function" { return workspace }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Live editor did not load")
        return workspace
    }

    @MainActor private func key(_ text: String, code: UInt16, in workspace: Workspace, flags: NSEvent.ModifierFlags = []) async throws {
        let window = try XCTUnwrap(workspace.window)
        window.makeFirstResponder(workspace.mediaView)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @MainActor func testLeftFromEmptyBulletMovesToPreviousBodyEnd() async throws {
        for heading in ["Updates:\n", ""] {
            let original = heading + "- Filipino dish\n- "
            let workspace = try await workspace(original)
            let view = workspace.mediaView
            _ = try await view.evaluateJavaScript("""
                const block=document.querySelector('.text');block.focus();
                const body=block.querySelectorAll('.list-marker')[1].nextSibling,range=document.createRange();
                range.setStart(body,1);range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);
                """)
            try await key("\u{F702}", code: 123, in: workspace)
            let result = try await view.evaluateJavaScript("""
                (()=>{
                  const body=document.querySelector('.list-marker').nextSibling,selection=getSelection(),expected=document.createRange();
                  expected.setStart(body,body.length);expected.collapse(true);
                  const actual=selection.getRangeAt(0);
                  updateTextCaret();
                  return [actual.compareBoundaryPoints(Range.START_TO_START,expected)===0,source(),
                    !document.getElementById('text-caret').hidden];
                })()
                """) as? [Any]
            XCTAssertEqual(result?[0] as? Bool, true, "Left must cross the bullet prefix in one press")
            XCTAssertEqual(result?[1] as? String, original)
            XCTAssertEqual(result?[2] as? Bool, true)
            try await key("!", code: 18, in: workspace)
            let edited = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(edited, heading + "- Filipino dish!\n- ")
        }
    }

    @MainActor func testLeftCrossesLoadedListPrefixesAndIndentation() async throws {
        for prefix in ["- ", "* ", "+ ", "• ", "12. ", "☐ ", "☑ ", "    - ", "\t- "] {
            for body in ["", "Next"] {
                let original = "- Filipino dish\n" + prefix + body
                let workspace = try await workspace(original)
                let view = workspace.mediaView
                _ = try await view.evaluateJavaScript("""
                    const block=document.querySelector('.text');block.focus();
                    const body=block.querySelectorAll('.list-marker')[1].nextSibling,range=document.createRange();
                    range.setStart(body,1);range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);
                    """)
                try await key("\u{F702}", code: 123, in: workspace)
                let line = try await view.evaluateJavaScript("currentLine()?.prefix") as? String
                XCTAssertEqual(line, "- Filipino dish", "Prefix: \(prefix), body: \(body)")
                try await key("!", code: 18, in: workspace)
                let edited = try await view.evaluateJavaScript("source()") as? String
                XCTAssertEqual(edited, original.replacingOccurrences(of: "dish\n", with: "dish!\n"))
            }
        }
    }

    @MainActor func testLeftAfterNativeListContinuationAndUndo() async throws {
        let workspace = try await workspace("Updates:\n- Filipino dish")
        let view = workspace.mediaView
        _ = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const body=block.querySelector('.list-marker').nextSibling,range=document.createRange();
            range.setStart(body,body.length);range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);
            """)
        try await key("\r", code: 36, in: workspace)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("source()")) as? String == "Updates:\n- Filipino dish\n- " { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await key("\u{F702}", code: 123, in: workspace)
        let line = try await view.evaluateJavaScript("currentLine()?.prefix") as? String
        XCTAssertEqual(line, "- Filipino dish")
        try await key("!", code: 18, in: workspace)
        let expected = "Updates:\n- Filipino dish!\n- "
        let edited = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(edited, expected)
        _ = try await view.evaluateJavaScript("document.execCommand('undo')")
        let undone = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(undone, "Updates:\n- Filipino dish\n- ")
        _ = try await view.evaluateJavaScript("document.execCommand('redo')")
        let redone = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(redone, expected)
        for _ in 0..<100 {
            if workspace.editor.string == expected { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(workspace.editor.string, expected)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try workspace.store.load().first?.text, expected)
    }

    @MainActor func testLeftAtFirstItemAndWithinBodyRetainsNativeBehavior() async throws {
        let original = "    - First body"
        let workspace = try await workspace(original)
        let view = workspace.mediaView
        _ = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const body=block.querySelector('.list-marker').nextSibling,range=document.createRange();
            range.setStart(body,1);range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);
            """)
        try await key("\u{F702}", code: 123, in: workspace)
        let start = try await view.evaluateJavaScript("currentLine()?.prefix") as? String
        XCTAssertEqual(start, "    - ")
        _ = try await view.evaluateJavaScript("""
            (()=>{const body=document.querySelector('.list-marker').nextSibling;
            getSelection().collapse(body,body.length);})()
            """)
        try await key("\u{F702}", code: 123, in: workspace)
        let middle = try await view.evaluateJavaScript("currentLine()?.prefix") as? String
        XCTAssertEqual(middle, "    - First bod")
        try await key("\u{F702}", code: 123, in: workspace, flags: .shift)
        let selected = try await view.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(selected, "d")
        let unchanged = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(unchanged, original)
    }
}
