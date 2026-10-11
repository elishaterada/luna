import AppKit
import XCTest
import LunaCore
@testable import Luna

final class EditorBehaviorTests: XCTestCase {
    @MainActor func testLiveWrappedListsKeepTheirBodyIndent() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let body = "Build a art museum featuring real art from sculpture to paintings that are legal to display"
        let original = "Help\n- \(body)\n12. \(body)\n  - \(body)\nOrdinary text"
        try store.save(Note(text: original, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text');block.style.width='320px';
              const aligned=[...block.querySelectorAll('.list-marker')].map(marker=>{
                const node=marker.nextSibling,range=document.createRange();
                let first=null,wrap=null;
                for(let i=0;i<node.length;i++) {
                  if(/[\\s\\u200B]/.test(node.textContent[i]))continue;
                  range.setStart(node,i);range.setEnd(node,i+1);
                  const rect=[...range.getClientRects()].at(-1);
                  if(!first)first=rect;else if(rect.top>first.top+1){wrap=rect;break;}
                }
                return !!wrap&&Math.abs(wrap.left-first.left)<1;
              });
              const singleLine=[...block.querySelectorAll('.list-marker:not(.bullet-marker)')].every(marker=>
                marker.getBoundingClientRect().height<=parseFloat(getComputedStyle(block).lineHeight)+.1);
              return [aligned,source(),singleLine];
            })()
            """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? [Bool], [true, true, true], "Wrapped bullets, numbers, and nested items align with their first body character")
        XCTAssertEqual(values[1] as? String, original)
        XCTAssertEqual(values[2] as? Bool, true, "Double-digit markers must stay on one visual line")
        // Continue a loaded item through WebKit's native paragraph path, then
        // indent/outdent it. Layout must not alter the portable source or Undo.
        let continued = try await view.callAsyncJavaScript("""
            const block=document.querySelector('.text'),marker=block.querySelectorAll('.list-marker')[1];
            block.focus();const text=marker.nextSibling,range=document.createRange();range.setStart(text,text.length);range.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(range);
            const key=(key,shiftKey=false)=>document.dispatchEvent(new KeyboardEvent('keydown',{key,shiftKey,bubbles:true,cancelable:true}));
            key('Enter');document.execCommand('insertText',false,body);key('Tab');key('Tab',true);
            const node=getSelection().anchorNode,index=node.textContent.search(/[^\\s\\u200B]/),first=document.createRange();first.setStart(node,index);first.setEnd(node,index+1);
            const firstRect=[...first.getClientRects()].at(-1);let wrapped=null;
            for(let i=index+1;i<node.length;i++) {
              if(/[\\s\\u200B]/.test(node.textContent[i]))continue;
              const r=document.createRange();r.setStart(node,i);r.setEnd(node,i+1);
              const rect=[...r.getClientRects()].at(-1);if(rect.top>firstRect.top+1){wrapped=rect;break;}
            }
            const before=source();document.execCommand('undo');const undone=source();document.execCommand('redo');
            return [!!wrapped&&Math.abs(wrapped.left-firstRect.left)<1,before,source(),undone!==before];
            """, arguments: ["body": body], in: nil, contentWorld: .page) as? [Any]
        let expected = original.replacingOccurrences(of: "\n  - ", with: "\n13. \(body)\n  - ")
        XCTAssertEqual(continued?[0] as? Bool, true)
        XCTAssertEqual(continued?[1] as? String, expected)
        XCTAssertEqual(continued?[2] as? String, expected)
        XCTAssertEqual(continued?[3] as? Bool, true)
        for _ in 0..<100 {
            if workspace.editor.string == expected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, expected)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().first?.text, expected)
    }
    @MainActor func testTypedNestedListWrappingUsesItsOwnParagraph() async throws {
        _ = NSApplication.shared
        preference("editor.tabWidth", 4)
        preference("editor.useTabs", false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        try store.save(Note(text: "- Loaded item\n    - Loaded child", language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let window = try XCTUnwrap(workspace.window)
        window.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("document.querySelector('.text').style.width='320px';document.querySelector('.text').focus();selectAllNote();")
        func send(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code)))
        }
        try send("\u{7f}", 51)
        try await Task.sleep(nanoseconds: 100_000_000)
        for character in "- First museum" {
            try send(String(character), character == "-" ? 27 : character == " " ? 49 : character == "F" ? 3 : 0, character.isUppercase ? .shift : [])
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try send("\r", 36)
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await view.evaluateJavaScript("document.execCommand('insertText',false,'Build another museum with a sufficiently long description to wrap across multiple lines and remain aligned');")
        try send("\t", 48)
        try await Task.sleep(nanoseconds: 50_000_000)
        let result = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text');
              const marker=block.querySelectorAll('.list-marker')[1],node=marker.nextSibling,r=document.createRange();let first=null,wrap=null;
              for(let i=0;i<node.length;i++) {
                if(/[\\s\\u200B]/.test(node.textContent[i]))continue;
                r.setStart(node,i);r.setEnd(node,i+1);const rect=[...r.getClientRects()].at(-1);
                if(!first)first=rect;else if(rect.top>first.top+1){wrap=rect;break;}
              }
              return [!!wrap&&Math.abs(wrap.left-first.left)<1,source()];
            })()
            """) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? String, "- First museum\n    - Build another museum with a sufficiently long description to wrap across multiple lines and remain aligned")
    }
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
    @MainActor func testTabIndentsListMarkersAndShiftTabOutdents() {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        let editor = EditorView(usingTextLayoutManager: true)
        for marker in ["• ", "12. ", "☐ "] {
            editor.string = marker + "Item"
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertTab(nil)
            XCTAssertEqual(editor.string, "  " + marker + "Item")
            editor.insertTab(nil)
            XCTAssertEqual(editor.string, "    " + marker + "Item")
            editor.insertBacktab(nil)
            XCTAssertEqual(editor.string, "  " + marker + "Item")
            editor.insertNewline(nil)
            XCTAssertTrue(editor.string.hasSuffix("\n  " + (marker == "12. " ? "13. " : marker)))
        }
        preference("editor.useTabs", true)
        editor.string = "• Item"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "\t• Item")
        XCTAssertEqual(editor.selectedRange().location, 3)
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, "• Item")
        XCTAssertEqual(editor.selectedRange().location, 2)
        editor.string = "```\n• code"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "```\n• code\t")
    }
    @MainActor func testSelectedListsIndentTogetherWithoutReplacingText() {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        let editor = EditorView(usingTextLayoutManager: true)
        let original = "• First 🌙\n  • Child\n12. Last\nOutside"
        editor.string = original
        let selectedLength = (original as NSString).range(of: "Outside").location
        editor.setSelectedRange(NSRange(location: 0, length: selectedLength))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  • First 🌙\n    • Child\n  12. Last\nOutside")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: selectedLength + 6))
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: selectedLength))
        preference("editor.useTabs", true)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "\t• First 🌙\n\t  • Child\n\t12. Last\nOutside")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, original)
    }

    @MainActor func testPartialListSelectionPreservesProseAndFencedCode() {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        let editor = EditorView(usingTextLayoutManager: true)
        editor.string = "• First\nProse\n```\n• Code\n```\n☐ Last"
        editor.setSelectedRange(NSRange(location: 3, length: (editor.string as NSString).length - 5))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  • First\nProse\n```\n• Code\n```\n  ☐ Last")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (editor.string as NSString).length))
    }

    @MainActor func testSelectedListIndentCanBeUndoneAsOneEdit() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let editor = workspace.editor
        editor.formatsLists = true // Exercise the list utility with the workspace's undo manager.
        editor.string = "• First\n• Second"
        let original = editor.string
        editor.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        undo.beginUndoGrouping()
        editor.insertTab(nil)
        undo.endUndoGrouping()
        XCTAssertNotEqual(editor.string, original)
        undo.undo()
        XCTAssertEqual(editor.string, original)
        undo.redo()
        XCTAssertTrue(editor.string.contains("• First\n"))
        XCTAssertTrue(editor.string.hasSuffix("• Second"))
    }

    @MainActor func testListBackspaceTreatsMarkerAndGapAsOneUnit() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        for marker in ["• ", "12. ", "☐ ", "☑ "] {
            editor.string = "    " + marker + "Text"
            editor.setSelectedRange(NSRange(location: ("    " + marker as NSString).length, length: 0))
            editor.deleteBackward(nil)
            XCTAssertEqual(editor.string, "Text")
            XCTAssertEqual(editor.selectedRange().location, 0)
            editor.string = "• First\n    " + marker
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.deleteBackward(nil)
            XCTAssertEqual(editor.string, "• First")
            editor.string = marker + "Text"
            editor.setSelectedRange(NSRange(location: (marker as NSString).length - 1, length: 1))
            editor.deleteBackward(nil)
            XCTAssertEqual(editor.string, "Text", "Selecting the marker separator must not make it independently deletable")
        }
        editor.string = "    • First"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "    • First\n    • ")
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "    • First")
        editor.string = "• First\n• \n• Last"
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• First\n• Last")
        editor.string = "• \n• Last"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• Last")
        editor.string = "• First\r\n• "
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• First")
        editor.string = "• Text"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• Tex")
        editor.string = "```\n• Code"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "```\n•Code")
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

extension EditorBehaviorTests {
    @MainActor func testDeletingLastLiveListLetterPreservesEmptyMarker() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for prefix in ["- ", "* ", "+ ", "• ", "1. ", "☐ ", "☑ "] {
            for body in ["a", ""] {
                // A new page gives each scenario its own native Undo history.
                // WebKit can coalesce consecutive deletes differently across OS versions.
                view.show(Note(text: prefix + body, language: "Markdown"), store: store,
                          fontSize: 18, appearance: NSAppearance(named: .darkAqua)!)
                for _ in 0..<100 {
                    if !view.isLoading,
                       (try? await view.evaluateJavaScript("document.querySelector('.list-marker')?.nextSibling?.textContent")) as? String == "\u{200B}" + body { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let result = try await view.callAsyncJavaScript("""
                    const block=document.querySelector('.text');block.focus();
                    const text=block.querySelector('.list-marker').nextSibling,range=document.createRange();
                    range.setStart(text,text.textContent.length);range.collapse(true);
                    getSelection().removeAllRanges();getSelection().addRange(range);
                    function backspace() {
                      const event=new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true});
                      document.dispatchEvent(event);if(!event.defaultPrevented)document.execCommand('delete');
                    }
                    backspace();
                    if(body)return [source()];
                    const exited=source();
                    document.execCommand('undo');const restored=source();
                    document.execCommand('redo');const redone=source();
                    document.execCommand('undo');const restoredAgain=source();
                    document.execCommand('insertText',false,'t');
                    const normal=getComputedStyle(getSelection().anchorNode.parentElement).fontSize===getComputedStyle(block).fontSize;
                    return [exited,restored,redone,restoredAgain,source(),String(normal)];
                    """, arguments: ["body": body], in: nil, contentWorld: .page) as? [String]
                let expected = body.isEmpty ? ["", prefix, "", prefix, prefix + "t", "true"] : [prefix]
                XCTAssertEqual(result, expected, "Deleting a body letter preserves \(prefix); undoing its removal permits normal body typing")
            }
        }
    }
    @MainActor func testBackspaceAfterRemovingListPrefixJoinsLineImmediately() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        window.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("""
            (()=>{
              const b=document.querySelector('.text');b.focus();
              document.execCommand('insertText',false,'Shopping');document.execCommand('insertParagraph');
              document.execCommand('insertText',false,'- ');document.execCommand('insertText',false,'Apples');
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
              document.execCommand('insertText',false,'Bread');
              const body=b.querySelectorAll('.list-marker')[1].nextSibling,r=document.createRange();r.setStart(body,1);r.collapse(true);
              getSelection().removeAllRanges();getSelection().addRange(r);
            })()
            """)
        for expected in ["Shopping\n- Apples\nBread", "Shopping\n- ApplesBread"] {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)))
            try await Task.sleep(nanoseconds: 50_000_000)
            let source = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(source, expected, "An invisible anchor must not consume an extra Backspace")
        }
    }

    @MainActor func testLiveSelectAllThenNativeDeleteOrReplacement() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof selectAllNote")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for (characters, code, expected): (String, UInt16, String) in [("\u{7f}", 51, ""), ("r", 15, "r")] {
            window.makeFirstResponder(view)
            _ = try await view.evaluateJavaScript("(()=>{const b=document.querySelector('.text');b.innerText='Weekend plan\\n- Buy groceries\\n- Cook dinner';decorateListMarkers(b);b.focus();selectAllNote();})()")
            let focus = try await view.evaluateJavaScript("document.activeElement.className") as? String
            XCTAssertEqual(focus, "text", "Select All must keep an editable element focused")
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
            try await Task.sleep(nanoseconds: 50_000_000)
            let source = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(source, expected)
            let highlighted = try await view.evaluateJavaScript("document.querySelector('article').classList.contains('whole-note-selected')") as? Bool
            XCTAssertEqual(highlighted, false)
            if expected.isEmpty {
                window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)))
                try await Task.sleep(nanoseconds: 50_000_000)
                let continued = try await view.evaluateJavaScript("source()") as? String
                XCTAssertEqual(continued, "r", "Typing after clearing must keep focus")
            }
        }
    }

    @MainActor func testShiftUpSelectionDeletesListLineAndKeepsNormalTyping() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        try store.save(Note(text: "First\n- Alpha\n- Bravo", language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        window.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("""
            (()=>{const b=document.querySelector('.text'),body=b.querySelectorAll('.list-marker')[1].nextSibling,r=document.createRange();
              b.focus();r.setStart(body,1);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);})()
            """)
        for (characters, code, flags): (String, UInt16, NSEvent.ModifierFlags) in [("\u{F700}",126,.shift),("\u{7f}",51,[]),("x",7,[])] {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let source = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(source, "First\n- xBravo")
        let normal = try await view.evaluateJavaScript("getComputedStyle(getSelection().anchorNode.parentElement).fontSize===getComputedStyle(document.querySelector('.text')).fontSize") as? Bool
        XCTAssertEqual(normal, true)
    }

    @MainActor func testWholeNoteCutAndPasteUsePortableSourceAndUndo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof selectAllNote")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = try await view.evaluateJavaScript("""
            (()=>{
              const b=document.querySelector('.text');b.innerText='Plan\\n* First\\n+ Second';decorateListMarkers(b);b.focus();selectAllNote();
              const clipboard=new DataTransfer();b.dispatchEvent(new ClipboardEvent('cut',{clipboardData:clipboard,bubbles:true,cancelable:true}));
              const copied=clipboard.getData('text/plain'),empty=source();document.execCommand('undo');
              const restored=source();selectAllNote();
              clipboard.setData('text/plain','New plan\\n- Replacement');
              b.dispatchEvent(new ClipboardEvent('paste',{clipboardData:clipboard,bubbles:true,cancelable:true}));
              const pasted=source();document.execCommand('undo');
              return [copied,empty,restored,pasted,source()];
            })()
            """) as? [String]
        XCTAssertEqual(state, ["Plan\n* First\n+ Second", "", "Plan\n* First\n+ Second", "New plan\n- Replacement", "Plan\n* First\n+ Second"])
    }

    @MainActor func testLiveSelectAllMixedContentCanBeReplacedAndUndone() async throws {
        _ = NSApplication.shared
        for original in ["First\n[Bookmark](http://127.0.0.1:1/review)\n- Last", "[Bookmark](http://127.0.0.1:1/review)\n- Last"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try RecoveryStore(directory: root)
            try store.save(Note(text: original, language: "Markdown"))
            let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
            defer { workspace.close() }
            workspace.showWindow(nil)
            let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript("document.querySelector('figure.bookmark') !== null")) as? Bool == true { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            window.makeFirstResponder(view)
            _ = try await view.evaluateJavaScript("selectAllNote();")
            func send(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
                window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
            }
            try send("r", 15)
            try await Task.sleep(nanoseconds: 50_000_000)
            try send("e", 14)
            try await Task.sleep(nanoseconds: 50_000_000)
            var source = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(source, "re")
            _ = try await view.evaluateJavaScript("document.execCommand('undo');")
            source = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(source, original, "Undo must restore text and bookmark")
            _ = try await view.evaluateJavaScript("document.execCommand('redo');")
            source = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(source, "re", "Redo restores the full replacement word")
            _ = try await view.evaluateJavaScript("document.execCommand('undo');selectAllNote();")
            try send("\u{7f}", 51)
            try await Task.sleep(nanoseconds: 50_000_000)
            source = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(source, "")
            try send("r", 15)
            try await Task.sleep(nanoseconds: 50_000_000)
            source = try await view.evaluateJavaScript("source()") as? String
            XCTAssertEqual(source, "r")
        }
    }

    @MainActor func testTypingListsAfterNativeParagraphIndentationKeepsLayout() async throws {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2); preference("editor.useTabs", false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.evaluateJavaScript("""
            (()=>{
              document.querySelector('.text').focus();
              const text=value=>document.execCommand('insertText',false,value),key=(key,shiftKey=false)=>{
                const event=new KeyboardEvent('keydown',{key,shiftKey,bubbles:true,cancelable:true});document.dispatchEvent(event);
                if(!event.defaultPrevented&&key==='Enter')document.execCommand('insertParagraph');
              };
              text('Weekend plan');key('Enter');text('- ');text('Buy groceries');key('Enter');text('Cook dinner');
              key('Tab');text(' tonight');key('Tab',true);key('Enter');text('Wash dishes');key('Enter');key('Enter');
              text('1. ');text('Prepare');key('Enter');text('Cook');key('Enter');text('Serve');
              const markers=[...document.querySelectorAll('.list-marker')];
              return [source(),markers[0].getBoundingClientRect().left,markers[3].getBoundingClientRect().left,
                getComputedStyle(markers[3].parentElement).fontSize];
            })()
            """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? String, "Weekend plan\n- Buy groceries\n- Cook dinner tonight\n- Wash dishes\n1. Prepare\n2. Cook\n3. Serve")
        XCTAssertEqual(try XCTUnwrap(values[1] as? Double), try XCTUnwrap(values[2] as? Double), accuracy: 1)
        XCTAssertEqual(values[3] as? String, "18px")
    }

    @MainActor func testLiveTabAndBacktabIndentSelectedLists() async throws {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.evaluateJavaScript("""
            (()=>{
              const b=document.querySelector('.text');b.innerText='Plan\\n- First\\n- Second';decorateListMarkers(b);b.focus();
              const body=b.querySelectorAll('.list-marker')[1].nextSibling,r=document.createRange();r.setStart(body,body.length);r.collapse(true);
              getSelection().removeAllRanges();getSelection().addRange(r);
              const tab=new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true});document.dispatchEvent(tab);
              const indented=source();
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true}));
              return [tab.defaultPrevented,indented,source(),document.activeElement===b];
            })()
            """) as? [Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertEqual(values[1] as? String, "Plan\n- First\n  - Second")
        XCTAssertEqual(values[2] as? String, "Plan\n- First\n- Second")
        XCTAssertEqual(values[3] as? Bool, true)
        let selected = try await view.evaluateJavaScript("""
            (()=>{
              const b=document.querySelector('.text'),markers=b.querySelectorAll('.list-marker'),r=document.createRange();
              r.setStartBefore(markers[0]);r.setEnd(markers[1].nextSibling,markers[1].nextSibling.length);
              getSelection().removeAllRanges();getSelection().addRange(r);
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
              const indented=source();
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true}));
              const restored=source(),collapsed=getSelection().isCollapsed;
              return [indented,restored,collapsed];
            })()
            """) as? [Any]
        let lines = try XCTUnwrap(selected)
        XCTAssertEqual(lines[0] as? String, "Plan\n  - First\n  - Second")
        XCTAssertEqual(lines[1] as? String, "Plan\n- First\n- Second")
        XCTAssertEqual(lines[2] as? Bool, false)
    }

    @MainActor func testSelectedLiveListIndentationUndoIsAtomicWithNativeTab() async throws {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2); preference("editor.useTabs", false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        let original = "Plan\n- First\n- Second"
        try store.save(Note(text: original, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        window.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("""
            (()=>{const b=document.querySelector('.text');b.replaceChildren();b.focus();
              document.execCommand('insertText',false,'Plan');document.execCommand('insertParagraph');
              document.execCommand('insertText',false,'- ');document.execCommand('insertText',false,'First');
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
              document.execCommand('insertText',false,'Second');
              const m=b.querySelectorAll('.list-marker'),r=document.createRange();
              r.setStartBefore(m[0]);r.setEnd(m[1].nextSibling,m[1].nextSibling.length);getSelection().removeAllRanges();getSelection().addRange(r);})()
            """)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)))
        try await Task.sleep(nanoseconds: 50_000_000)
        var source = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(source, "Plan\n  - First\n  - Second")
        _ = try await view.evaluateJavaScript("document.execCommand('undo');")
        source = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(source, original, "One Undo restores all selected list indentation")
    }

    @MainActor func testLiveCaretTracksNativeKeyboardInput() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        try store.save(Note(text: "fdsafsda\nfdsafdsa\n- \n\nAfter", language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let window = try XCTUnwrap(workspace.window)
        window.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text'),text=block.querySelector('.list-marker').nextSibling;
            text.textContent=text.textContent.slice(0,1)+'\\u200B'+text.textContent.slice(1);
            block.focus();const range=document.createRange();range.setStart(text,1);range.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.getElementById('text-caret').style.animation='none';
            """)
        var typed = ""
        for (letter, code): (String, UInt16) in [("f", 3), ("d", 2), ("s", 1), ("a", 0)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: code))
            window.sendEvent(event)
            typed += letter
            for _ in 0..<50 {
                if workspace.editor.string.contains("- " + typed + "\n") { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(workspace.editor.string.contains("- " + typed + "\n"))
            let metrics = try await view.evaluateJavaScript("""
                (()=>{
                  const selection=getSelection(),last=document.createRange();
                  last.setStart(selection.anchorNode,selection.anchorOffset-1);last.setEnd(selection.anchorNode,selection.anchorOffset+(selection.anchorNode.textContent[selection.anchorOffset]==='\\u200B'?1:0));
                  const indicator=document.getElementById('text-caret');
                  return [last.getBoundingClientRect().right,indicator.getBoundingClientRect().left,indicator.hidden];
                })()
                """) as? [Any]
            let sample = try XCTUnwrap(metrics)
            XCTAssertEqual(try XCTUnwrap(sample[1] as? Double), try XCTUnwrap(sample[0] as? Double), accuracy: 1)
            XCTAssertEqual(sample[2] as? Bool, false)
        }
        for (characters, code, offset): (String, UInt16, Int) in [("\u{F702}", 123, 4), ("\u{F703}", 124, 5), ("\u{7f}", 51, 4), ("a", 0, 5)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
            try await Task.sleep(nanoseconds: 30_000_000)
            let metrics = try await view.evaluateJavaScript("""
                (()=>{
                  const selection=getSelection(),last=document.createRange();
                  last.setStart(selection.anchorNode,selection.anchorOffset-1);last.setEnd(selection.anchorNode,selection.anchorOffset+(selection.anchorNode.textContent[selection.anchorOffset]==='\\u200B'?1:0));
                  const indicator=document.getElementById('text-caret');
                  return [last.getBoundingClientRect().right,indicator.getBoundingClientRect().left,indicator.hidden,selection.anchorOffset];
                })()
                """) as? [Any]
            let sample = try XCTUnwrap(metrics)
            XCTAssertEqual(try XCTUnwrap(sample[1] as? Double), try XCTUnwrap(sample[0] as? Double), accuracy: 1)
            XCTAssertEqual(sample[2] as? Bool, false)
            XCTAssertEqual(sample[3] as? Int, offset)
        }
    }
    @MainActor func testLiveCaretBeforeTrailingAnchorMatchesLastVisibleLetter() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof updateTextCaret")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.callAsyncJavaScript("""
            const block=document.querySelector('.text'),samples=[];
            for(const size of [12,18,24])for(const fullLayout of [false,true])for(const tail of ['', '\\u200B', '\\u200B\\n\\nBusiness idea:', 'split', 'span', 'afterspan']) {
              block.style.fontSize=size+'px';
              block.textContent=(fullLayout?'Help\\n- Fishing -> Menu item\\n- Under water\\n1. Under water\\n\\nfdsafsda\\nfdsafdsa\\n- fdsa\\n- fdfsda\\n- fdsafdsa':'- fdsafdsa')+(tail==='split'||tail==='span'||tail==='afterspan'?'':tail);
              decorateListMarkers(block);block.focus();
              let text=block.querySelectorAll('.list-marker')[fullLayout?5:0].nextSibling;
              if(tail==='split')text.after(document.createTextNode('\\u200B\\n\\nBusiness idea:'));
              if(tail==='span'||tail==='afterspan'){const span=document.createElement('span');span.textContent='\\u200B';text.after(span);if(tail==='afterspan')span.after(document.createTextNode('\\n\\nBusiness idea:'));}
              const offset=text.textContent.indexOf('fdsafdsa')+8,r=document.createRange();
              r.setStart(text,offset);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);updateTextCaret();
              const glyph=document.createRange();glyph.setStart(text,offset-1);glyph.setEnd(text,offset+(text.textContent[offset]==='\\u200B'?1:0));
              const g=glyph.getBoundingClientRect(),c=document.getElementById('text-caret').getBoundingClientRect();
              samples.push({tail,size,fullLayout,expected:g.right,actual:c.left,offset,selectionOffset:getSelection().anchorOffset});
            }
            return JSON.stringify(samples);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(result?.data(using: .utf8))) as? [[String: Any]])
        for sample in samples {
            XCTAssertEqual(sample["selectionOffset"] as? Int, sample["offset"] as? Int, "Drawing the caret must leave the editing position unchanged")
            XCTAssertEqual(try XCTUnwrap(sample["actual"] as? Double), try XCTUnwrap(sample["expected"] as? Double), accuracy: 1, "\(sample)")
        }
    }

    @MainActor func testLiveCaretTracksEachTypedLetter() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof updateTextCaret")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.callAsyncJavaScript("""
            const block=document.querySelector('.text'),indicator=document.getElementById('text-caret');
            indicator.style.animation='none';const samples=[];
            for(const prefix of ['', '- ', 'multiline', 'wrapped']) {
              block.replaceChildren();block.focus();
              block.style.width=prefix==='wrapped'?'70px':'';
              const start=document.createRange();
              if(prefix==='multiline') {
                block.textContent='fdsafsda\\nfdsafdsa\\n- fdsa\\n\\nBusiness idea';decorateListMarkers(block);
                const body=block.querySelector('.list-marker').nextSibling;
                start.setStart(body,body.textContent.indexOf('fdsa')+4);start.collapse(true);
              } else {start.selectNodeContents(block);start.collapse(false);}
              getSelection().removeAllRanges();getSelection().addRange(start);
              if(prefix&&prefix!=='multiline')document.execCommand('insertText',false,prefix==='wrapped'?'- ':prefix);
              if(prefix==='- ') {
                const marker=block.querySelector('.list-marker');
                samples.push({prefix:'new bullet',letter:'space',expected:marker.getBoundingClientRect().right+parseFloat(getComputedStyle(marker).marginRight),
                  actual:indicator.getBoundingClientRect().left,visible:!indicator.hidden});
              }
              for(const letter of 'fdsafsda') {
                document.execCommand('insertText',false,letter);
                const selection=getSelection(),last=document.createRange();
                last.setStart(selection.anchorNode,selection.anchorOffset-1);last.setEnd(selection.anchorNode,selection.anchorOffset);
                const glyph=[...last.getClientRects()].at(-1),caret=indicator.getBoundingClientRect();
                const expected=glyph.right,expectedTop=glyph.top+(glyph.height-parseFloat(getComputedStyle(block).fontSize))/2;
                samples.push({prefix,letter,expected,expectedTop,actual:caret.left,actualTop:caret.top,visible:!indicator.hidden});
              }
            }
            block.textContent='Before';block.focus();
            const end=document.createRange();end.selectNodeContents(block);end.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(end);
            for(let line=0;line<3;line++) {
              document.execCommand('insertParagraph');
              const row=block.lastElementChild;
              samples.push({prefix:'empty paragraph',letter:line,expected:row.getBoundingClientRect().left,
                actual:indicator.getBoundingClientRect().left,visible:!indicator.hidden});
            }
            return JSON.stringify(samples);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(result?.data(using: .utf8))) as? [[String: Any]])
        XCTAssertEqual(samples.count, 36)
        for sample in samples {
            XCTAssertEqual(sample["visible"] as? Bool, true)
            let expected = try XCTUnwrap(sample["expected"] as? Double)
            let actual = try XCTUnwrap(sample["actual"] as? Double)
            XCTAssertEqual(actual, expected, accuracy: 1, "Caret must follow \(sample["prefix"] ?? "")\(sample["letter"] ?? "")")
            if let expectedTop = sample["expectedTop"] as? Double, let actualTop = sample["actualTop"] as? Double {
                XCTAssertEqual(actualTop, expectedTop, accuracy: 1, "Caret must follow the current visual line")
            }
        }
    }
    @MainActor func testMarkdownSourceDisplaysLiteralUnstyledText() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let note = Note(text: "# Heading\n• Item\n1. **bold**\n[Mention](https://example.com)", language: "Markdown")
        workspace.notes.append(note); workspace.select(note.id)
        workspace.showWindow(nil); workspace.toggleMarkdownPreview()
        let editor = workspace.editor
        XCTAssertEqual(editor.string, note.text)
        XCTAssertFalse(editor.formatsLists, "Source must not style or convert list prefixes")
        let content = try XCTUnwrap(editor.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let row = (note.text as NSString).lineRange(for: (note.text as NSString).range(of: "• Item"))
        XCTAssertNil(editor.textContentStorage(content, textParagraphWith: row), "Source must use normal paragraph geometry and font")
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.highlighter.highlight(editor)
        var colors: [NSColor] = []
        editor.textLayoutManager?.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, _ in
            if let color = attributes[.foregroundColor] as? NSColor { colors.append(color) }
            return true
        }
        XCTAssertFalse(colors.isEmpty)
        XCTAssertTrue(colors.allSatisfy { $0 == Theme.text }, "Source must not color Markdown syntax")
        editor.setSelectedRange(NSRange(location: 0, length: (note.text as NSString).length))
        editor.insertText("- ", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "- ", "Source typing must retain the literal marker")
        editor.insertText("item", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "- item\n", "Source Return must not insert a list marker")
    }
    @MainActor func testRestoredPrivateMarkdownUsesVirtualListSeparators() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let note = Note(text: "• Bullet\n1. Number", language: "Markdown")
        try store.save(note)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        XCTAssertTrue(workspace.richEditing)
        for _ in 0..<100 {
            if (try? await workspace.mediaView.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let gap = try await workspace.mediaView.evaluateJavaScript("[...document.querySelectorAll('.list-marker')].every(e=>!e.nextSibling.textContent.startsWith(' '))") as? Bool
        XCTAssertEqual(gap, true)
        let source = try await workspace.mediaView.evaluateJavaScript("source()") as? String
        XCTAssertEqual(source, note.text)
        workspace.toggleMarkdownPreview()
        XCTAssertFalse(workspace.richEditing)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(workspace.window?.firstResponder === workspace.editor, "A pending live focus must not steal Source view focus")
        let code = Note(text: "let value = 1", language: "Swift")
        workspace.notes.append(code); workspace.select(code.id, focusContent: true)
        XCTAssertFalse(workspace.richEditing)
        XCTAssertTrue(workspace.window?.firstResponder === workspace.editor)
    }
    @MainActor func testNewPrivateNotesHaveNoEditableListSeparator() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil); workspace.newNote()
        XCTAssertEqual(workspace.notes[workspace.index!].language, "Markdown")
        XCTAssertTrue(workspace.richEditing, "A new private note must use the list editor with virtual separators")
        guard workspace.richEditing else { return }
        for _ in 0..<100 {
            if (try? await workspace.mediaView.evaluateJavaScript("document.activeElement?.matches('.text')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let focused = try await workspace.mediaView.evaluateJavaScript("document.activeElement?.matches('.text')") as? Bool
        XCTAssertEqual(focused, true, "The new note must be ready to type without an extra click")
        _ = try await workspace.mediaView.evaluateJavaScript("document.execCommand('insertText',false,'1. ');")
        _ = try await workspace.mediaView.evaluateJavaScript("document.execCommand('insertText',false,'test');")
        _ = try await workspace.mediaView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));")
        _ = try await workspace.mediaView.evaluateJavaScript("document.execCommand('insertText',false,'test');")
        let result = try await workspace.mediaView.evaluateJavaScript("""
            (()=>{
              const markers=[...document.querySelectorAll('.list-marker')];
              const noSpaces=markers.length===2&&markers.every(marker=>
                !marker.textContent.includes(' ')&&!marker.nextSibling.textContent.startsWith(' '));
              const text=markers[0].nextSibling,range=document.createRange();
              range.setStart(text,0);range.setEnd(text,text.textContent.indexOf('test'));
              getSelection().removeAllRanges();getSelection().addRange(range);
              const noSelectableSpace=getSelection().toString().replaceAll('\u{200B}','')==='';
              return JSON.stringify({noSpaces,noSelectableSpace,source:source()});
            })()
            """) as? String
        XCTAssertEqual(result, "{\"noSpaces\":true,\"noSelectableSpace\":true,\"source\":\"1. test\\n2. test\"}")
        for _ in 0..<100 {
            if workspace.editor.string == "1. test\n2. test" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, "1. test\n2. test")
        XCTAssertTrue(workspace.flushRecovery())
        workspace.toggleMarkdownPreview()
        XCTAssertFalse(workspace.richEditing)
        workspace.toggleMarkdownPreview()
        XCTAssertTrue(workspace.richEditing, "Source view must allow returning to the normal note editor")
    }
    @MainActor func testTypingImmediatelyAfterCreatingNotePreservesFirstCharacter() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil); workspace.newNote()
        let window = try XCTUnwrap(workspace.window)
        for character in "List spacing check" {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: character == "L" ? .shift : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character).lowercased(), isARepeat: false, keyCode: 0))
            window.sendEvent(event)
        }
        for _ in 0..<100 {
            if workspace.editor.string == "List spacing check" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, "List spacing check")
    }
    @MainActor func testStartingBulletAfterExitingNumberedListHasNoEditableGap() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil); workspace.newNote()
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.activeElement?.matches('.text')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = try await view.evaluateJavaScript("""
            document.execCommand('insertText',false,'1. test');
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.execCommand('insertText',false,'test');
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.execCommand('insertText',false,'- ');document.execCommand('insertText',false,'bullet');
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.execCommand('insertText',false,'bullet');
            JSON.stringify({markers:document.querySelectorAll('.list-marker').length,
              gaps:[...document.querySelectorAll('.list-marker')].every(e=>!e.nextSibling.textContent.startsWith(' ')),
              source:source()});
            """) as? String
        XCTAssertEqual(state, "{\"markers\":4,\"gaps\":true,\"source\":\"1. test\\n2. test\\n- bullet\\n- bullet\"}")
    }
    @MainActor func testPlainTextModeKeepsMarkersAndPastedLinksLiteral() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let note = Note(text: "• Item\n[Mention](https://example.com)", language: "Plain Text")
        workspace.notes.append(note); workspace.select(note.id, focusContent: true)
        XCTAssertFalse(workspace.richEditing)
        XCTAssertFalse(workspace.editor.formatsLists)
        let editor = workspace.editor
        editor.setSelectedRange(NSRange(location: (note.text as NSString).length, length: 0))
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let previous { pasteboard.setString(previous, forType: .string) } }
        pasteboard.clearContents(); pasteboard.setString("https://example.com", forType: .string)
        editor.paste(nil)
        XCTAssertEqual(editor.string, note.text + "https://example.com")
        XCTAssertFalse(workspace.richEditing)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "• Item\n\n[Mention](https://example.com)https://example.com")
    }
    @MainActor func testTypingAfterCreatingLiveListsKeepsBodyStyle() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let original = "[URL](http://127.0.0.1:1/bullet-typing)\nPlain"
        try store.save(Note(text: original, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var expected = ""
        for (prefix, first, next) in [("- ", "-", "-"), ("* ", "*", "*"), ("+ ", "+", "+"), ("• ", "•", "•"),
                                     ("1. ", "1.", "2."), ("1) ", "1.", "2."), ("[ ] ", "☐", "☐")] {
            _ = try await view.callAsyncJavaScript("""
                const block=document.querySelector('.text');block.innerText='';block.focus();
                const range=document.createRange();range.selectNodeContents(block);range.collapse(false);
                getSelection().removeAllRanges();getSelection().addRange(range);
                document.execCommand('insertText',false,'Plain');document.execCommand('insertParagraph');
                for(const character of prefix)document.execCommand('insertText',false,character);
                """, arguments: ["prefix": prefix], in: nil, contentWorld: .page)
            _ = try await view.evaluateJavaScript("document.execCommand('insertText',false,'test');")
            _ = try await view.evaluateJavaScript("""
                document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
                """)
            _ = try await view.evaluateJavaScript("document.execCommand('insertText',false,'t');")
            let metrics = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text'),walker=document.createTreeWalker(block,NodeFilter.SHOW_TEXT);
              let normal=true,node;while(node=walker.nextNode()) {
                if(/[a-z]/i.test(node.textContent)&&!node.parentElement.closest('a'))
                  normal=normal&&getComputedStyle(node.parentElement).fontSize===getComputedStyle(block).fontSize
                    &&getComputedStyle(node.parentElement).fontWeight===getComputedStyle(block).fontWeight;
              }
              const typed=source();document.execCommand('insertText',false,' extra');
              const extra=source();document.execCommand('undo');const undone=source();
              document.execCommand('redo');const redone=source();
              const markers=[...block.querySelectorAll('.list-marker')];
              const adjacent=Math.abs(markers[1].getBoundingClientRect().top-markers[0].getBoundingClientRect().top-parseFloat(getComputedStyle(block).lineHeight))<.1;
              return JSON.stringify({normal,adjacent,source:redone,undoRedo:undone!==extra&&redone===extra});
            })()
            """) as? String
            expected = "Plain\n\(first) test\n\(next) t extra"
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(metrics?.data(using: .utf8))) as? [String: Any])
            XCTAssertEqual(result["normal"] as? Bool, true, "Typing after creating or continuing \(prefix) must retain the body font")
            XCTAssertEqual(result["adjacent"] as? Bool, true, "Return should place the next item immediately below the current item")
            XCTAssertEqual(result["source"] as? String, expected)
            XCTAssertEqual(result["undoRedo"] as? Bool, true)
        }
        for _ in 0..<100 {
            if workspace.editor.string == expected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, expected)
        XCTAssertTrue(workspace.flushRecovery())
    }
    @MainActor func testStandardMarkdownBulletsRoundTripCopyAndUndo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let original = "- Dash\n* Star\n+ Plus\n  - Child\n• Legacy\n```\n- Code\n```"
        let note = Note(text: original, language: "Markdown")
        try store.save(note)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 5 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text'),markers=[...block.querySelectorAll('.list-marker')];
              const roundTrip=source(),circles=markers.every(marker=>marker.textContent==='•');
              const prefixes=markers.map(marker=>marker.dataset.prefix);
              const gaps=markers.every(marker=>!marker.nextSibling.textContent.startsWith(' '));
              const selection=getSelection(),range=document.createRange();block.focus();
              const star=markers[1].nextSibling;
              range.setStartBefore(markers[1]);range.setEnd(star,star.textContent.indexOf('Star')+4);
              selection.removeAllRanges();selection.addRange(range);
              let copied='';const copy=new Event('copy',{bubbles:true,cancelable:true});
              Object.defineProperty(copy,'clipboardData',{value:{setData:(type,value)=>{copied=value;}}});
              document.dispatchEvent(copy);
              const first=markers[0].nextSibling;range.setStart(first,first.textContent.indexOf('Dash'));range.collapse(true);
              selection.removeAllRanges();selection.addRange(range);
              const key=new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true});
              document.dispatchEvent(key);if(!key.defaultPrevented)document.execCommand('delete');
              const removed=source();document.execCommand('undo');const restored=source();
              block.querySelector('.list-marker').textContent='changed';
              const edited=source();
              return JSON.stringify({roundTrip,circles,prefixes,gaps,copied,removed,restored,edited});
            })()
            """) as? String
        let metrics = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(result?.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(metrics["roundTrip"] as? String, original)
        XCTAssertEqual(metrics["circles"] as? Bool, true)
        XCTAssertEqual(metrics["prefixes"] as? [String], ["- ", "* ", "+ ", "- ", "• "])
        XCTAssertEqual(metrics["gaps"] as? Bool, true)
        XCTAssertEqual(metrics["copied"] as? String, "* Star")
        XCTAssertEqual(metrics["removed"] as? String, String(original.dropFirst(2)))
        XCTAssertEqual(metrics["restored"] as? String, original)
        XCTAssertEqual(metrics["edited"] as? String, "changed" + original.dropFirst(2))
        workspace.toggleMarkdownPreview()
        XCTAssertEqual(workspace.editor.string, original)
        XCTAssertFalse(workspace.editor.formatsLists)
        workspace.toggleMarkdownPreview()
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("source()")) as? String == original { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let reopened = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(reopened, original)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().first(where: { $0.id == note.id })?.text, original)
    }
    @MainActor func testLiveListBackspaceRemovesPrefixAndCaretUsesTextSize() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let original = "[URL](http://127.0.0.1:1/list-prefix)\n• Item"
        try store.save(Note(text: original, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text'),marker=block.querySelector('.list-marker');
              const text=marker.nextSibling,range=document.createRange();block.focus();
              range.setStart(text,text.textContent.indexOf('Item'));range.collapse(true);
              getSelection().removeAllRanges();getSelection().addRange(range);
              const editableSeparator=text.textContent.startsWith(' ');
              const copyRange=document.createRange();copyRange.setStartBefore(marker);copyRange.setEnd(text,text.textContent.length);
              getSelection().removeAllRanges();getSelection().addRange(copyRange);
              let copied='';const copy=new Event('copy',{bubbles:true,cancelable:true});
              Object.defineProperty(copy,'clipboardData',{value:{setData:(type,value)=>{copied=value;}}});
              document.dispatchEvent(copy);getSelection().removeAllRanges();getSelection().addRange(range);
              const key=new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true});
              document.dispatchEvent(key);if(!key.defaultPrevented)document.execCommand('delete');
              const plain=source();document.execCommand('undo');const restored=source();
              return JSON.stringify({editableSeparator,copied,plain,restored});
            })()
            """) as? String
        let metrics = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(result?.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(metrics["editableSeparator"] as? Bool, false)
        XCTAssertEqual(metrics["copied"] as? String, "• Item")
        XCTAssertEqual(metrics["plain"] as? String, "[URL](http://127.0.0.1:1/list-prefix)\nItem")
        XCTAssertEqual(metrics["restored"] as? String, original)
        _ = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text'),text=block.querySelector('.list-marker').nextSibling;
            const range=document.createRange();range.setStart(text,0);range.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            """)
        let bodyStart = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text');
              document.execCommand('insertText',false,'t');
              const normal=getComputedStyle(getSelection().anchorNode.parentElement).fontSize===getComputedStyle(block).fontSize;
              const edited=source();document.execCommand('undo');return JSON.stringify({normal,edited,restored:source()});
            })()
            """) as? String
        XCTAssertEqual(bodyStart, "{\"normal\":true,\"edited\":\"[URL](http://127.0.0.1:1/list-prefix)\\n• tItem\",\"restored\":\"[URL](http://127.0.0.1:1/list-prefix)\\n• Item\"}")
        let caret = try await view.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const range=document.createRange();range.selectNodeContents(block);range.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            const indicator=document.getElementById('text-caret');
            const textSized=!!indicator && !indicator.hidden && parseFloat(indicator.style.height)===parseFloat(getComputedStyle(block).fontSize);
            range.selectNodeContents(block);getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('selectionchange'));const selectionHidden=indicator.hidden;
            range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('compositionstart'));const compositionHidden=indicator.hidden;
            document.dispatchEvent(new Event('compositionend'));const compositionRestored=!indicator.hidden;
            window.dispatchEvent(new Event('blur'));document.dispatchEvent(new Event('selectionchange'));const blurHidden=indicator.hidden;
            window.dispatchEvent(new Event('focus'));
            const empty=document.createElement('div');empty.className='text';empty.contentEditable='true';document.body.append(empty);empty.focus();
            range.selectNodeContents(empty);range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('selectionchange'));const emptyVisible=!indicator.hidden;empty.remove();
            return JSON.stringify({textSized,selectionHidden,compositionHidden,compositionRestored,blurHidden,emptyVisible});
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(caret, "{\"textSized\":true,\"selectionHidden\":true,\"compositionHidden\":true,\"compositionRestored\":true,\"blurHidden\":true,\"emptyVisible\":true}")
        for _ in 0..<100 {
            if workspace.editor.string == original { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, original)
        XCTAssertTrue(workspace.flushRecovery())
    }
    @MainActor func testLiveListContentAlignmentAndSourceWhitespace() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let original = "[URL](http://127.0.0.1:1/alignment)\n• Bullet\n1. Number\n12. Twelve\n☐ Task\n  • Nested"
        try store.save(Note(text: original, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length")) as? Int == 5 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let geometry = try await view.evaluateJavaScript("""
            (()=>{
              const markers=[...document.querySelectorAll('.list-marker')];
              const positions=markers.slice(0,4).map(marker=>{
                const text=marker.nextSibling,range=document.createRange();
                range.setStart(text,0);range.setEnd(text,1);return range.getBoundingClientRect().left;
              });
              return JSON.stringify({aligned:Math.max(...positions)-Math.min(...positions)<.1,
                noLeadingGap:markers.slice(0,4).every(marker=>Math.abs(marker.getBoundingClientRect().left-document.querySelector('.text').getBoundingClientRect().left)<.1),
                unchanged:source()===\(String(reflecting: original))});
            })()
            """) as? String
        XCTAssertEqual(geometry, "{\"aligned\":true,\"noLeadingGap\":true,\"unchanged\":true}")
        let checked = try await view.evaluateJavaScript("""
            document.querySelectorAll('.list-marker')[3].dispatchEvent(new MouseEvent('click',{bubbles:true}));
            const checked=source().includes('☑ Task');document.execCommand('undo');checked && source()===\(String(reflecting: original));
            """) as? Bool
        XCTAssertEqual(checked, true, "Checkbox prefixes should toggle and undo without losing their source separator")
        let edited = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const range=document.createRange();range.selectNodeContents(block);range.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.execCommand('insertText',false,'Continued');source();
            """) as? String
        let expected = original + "\n  • Continued"
        XCTAssertEqual(edited, expected)
        for _ in 0..<100 {
            if workspace.editor.string == expected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, expected)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().first?.text, expected)
    }
    @MainActor func testLiveListsContinueAcrossRepeatedReturnsAndMentionConversion() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let url = "http://127.0.0.1:1/list-mention"
        try store.save(Note(text: "1. First\n[URL](\(url))", language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let numbers = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text');block.innerText='1. First';block.focus();
              const range=document.createRange();range.selectNodeContents(block);range.collapse(false);
              getSelection().removeAllRanges();getSelection().addRange(range);
              const enter=()=>document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
              enter();document.execCommand('insertText',false,'Second');
              enter();document.execCommand('insertText',false,'Third');
              enter();document.execCommand('insertText',false,'Fourth');
              return source();
            })()
            """) as? String
        XCTAssertEqual(numbers, "1. First\n2. Second\n3. Third\n4. Fourth")
        _ = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text');block.innerText='• ';block.focus();
            const range=document.createRange();range.selectNodeContents(block);range.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(range);
            insertSnippet('[URL](\(url))',true);
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));true;
            """)
        var restored = false
        for _ in 0..<100 {
            restored = (try? await view.evaluateJavaScript("!!document.querySelector('a.mention-link') && getSelection().anchorNode===document.querySelector('a.mention-link').nextSibling")) as? Bool == true
            if restored { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(restored)
        let bullets = try await view.evaluateJavaScript("""
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.execCommand('insertText',false,'Next');source();
            """) as? String
        XCTAssertEqual(bullets, "• [Mention](\(url))\n• Next")
        let layout = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text'),markers=[...block.querySelectorAll('.list-marker')];
              const marker=markers[1],body=getComputedStyle(block),style=getComputedStyle(marker);
              const metric=value=>Math.round(parseFloat(value)*100)/100;
              return JSON.stringify({count:markers.length,marker:marker.textContent,
                inset:metric(marker.getBoundingClientRect().left-block.getBoundingClientRect().left),gap:metric(style.marginRight),size:metric(style.fontSize),
                bodySize:metric(body.fontSize),lineHeight:metric(body.lineHeight),
                contentSize:metric(getComputedStyle(marker.nextSibling.parentElement).fontSize)});
            })()
            """) as? String
        XCTAssertEqual(layout, "{\"count\":2,\"marker\":\"•\",\"inset\":0,\"gap\":4.5,\"size\":26.1,\"bodySize\":18,\"lineHeight\":32.4,\"contentSize\":18}")
        for _ in 0..<100 {
            if workspace.editor.string == bullets { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, bullets)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().first?.text, bullets)
        let exit = try await view.evaluateJavaScript("""
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.execCommand('insertText',false,'Plain');source();
            """) as? String
        XCTAssertEqual(exit, "• [Mention](\(url))\n• Next\nPlain")
        let remainingMarkers = try await view.evaluateJavaScript("document.querySelectorAll('.list-marker').length") as? Int
        XCTAssertEqual(remainingMarkers, 2, "Exiting an empty item should also remove its visual marker inset")
        let undo = try await view.evaluateJavaScript("""
            document.execCommand('insertText',false,' extra');
            const typed=source();document.execCommand('undo');const undone=source();
            document.execCommand('redo');const redone=source();
            for(let i=0;i<15;i++)document.execCommand('undo');
            JSON.stringify({roundTrip:typed===redone&&undone!==typed,original:source()});
            """) as? String
        XCTAssertEqual(undo, "{\"roundTrip\":true,\"original\":\"• [Mention](\(url))\"}")
        let original = "• [Mention](\(url))"
        for _ in 0..<100 {
            if workspace.editor.string == original { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, original)
        XCTAssertTrue(workspace.flushRecovery())
    }
    @MainActor func testListsFormatContinueExitAndKeepCodeLiteral() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        editor.insertText("- ", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "- ")
        editor.insertText("[ ] Task", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "☐ Task")
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n☐ ")
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n")
        editor.insertText("3) Third", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n3. Third\n4. ")
        editor.formatsLists = false
        editor.string = ""; editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("- literal", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "- literal")
        XCTAssertEqual(NoteLists.formatted("- [x] Done\n* Item\n```\n- code\n```"), "☑ Done\n* Item\n```\n- code\n```")
        for marker in ["-", "*", "+", "•"] {
            XCTAssertEqual(NoteLists.formatted("\(marker) Item"), "\(marker) Item")
            XCTAssertEqual(NoteLists.continuation("  \(marker) Item")?.prefix, "  \(marker) ")
        }
    }
    @MainActor func testLiveListEditingAndVisibleMetadata() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        var note = Note(text: "Start\n[Preview](http://127.0.0.1:1/preview-test)", path: root.appendingPathComponent("note.md").path, language: "Markdown")
        note.dirty = true
        try store.save(note)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        XCTAssertTrue(workspace.updated.stringValue.hasPrefix("Updated "))
        XCTAssertFalse(workspace.notePath.isHidden)
        XCTAssertTrue(workspace.subtitle.isHidden)
        XCTAssertEqual(NotePathView.segments(for: note.path!).dropLast().last?.url?.path, root.path)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof currentLine")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await view.evaluateJavaScript("const block=document.querySelector('.text');block.innerText='';block.focus();document.execCommand('insertText',false,'- [ ] Task');")
        _ = try await view.callAsyncJavaScript("resolvePreview(0, title)", arguments: ["title": "A page title <safe>"], in: nil, contentWorld: .page)
        let previewTitle = try await view.evaluateJavaScript("document.querySelector('[data-preview]').textContent") as? String
        XCTAssertEqual(previewTitle, "A page title <safe>")
        let text = try await view.evaluateJavaScript("textSource(document.querySelector('.text'))") as? String
        XCTAssertEqual(text, "☐ Task")
        _ = try await view.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));")
        let source = try await view.evaluateJavaScript("source()") as? String
        XCTAssertTrue(source?.hasPrefix("☐ Task\n☐ ") == true)
    }
    func testURLPasteChoicesHaveDistinctPersistentRendering() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))
        XCTAssertEqual(URLPasteChoice.linkedSnippet(for: url.absoluteString), "[URL](https://example.com/path)")
        XCTAssertEqual(URLPasteChoice.linkedSnippet(for: "<iframe src='https://example.com/path'></iframe>"), "[URL](https://example.com/path)")
        XCTAssertNil(URLPasteChoice.linkedSnippet(for: "file:///private/secret"))
        XCTAssertFalse(NoteEmbeds.hasContent(URLPasteChoice.plain.snippet(for: url)))
        XCTAssertEqual(URLPasteChoice.preview.title, "Bookmark")
        XCTAssertEqual(URLPasteChoice.mention.snippet(for: url), "[Mention](https://example.com/path)")
        XCTAssertEqual(URLPasteChoice.preview.snippet(for: url), "\n[Bookmark](https://example.com/path)\n")
        for choice in [URLPasteChoice.linked, .mention, .preview, .embed] {
            let source = choice.snippet(for: url)
            XCTAssertTrue(NoteEmbeds.hasContent(source))
            XCTAssertEqual(NoteEmbeds.blocks(source).map(\.source).joined(separator: "\n"), source)
            let html = MediaNoteView.page(Note(text: source), fontSize: 18, dark: true, pageID: "test")
            XCTAssertEqual(html.contains("<iframe data-embed="), choice == .embed)
            if choice == .preview { XCTAssertTrue(html.contains("class=\"link-chip bookmark\"")) }
            if choice == .linked { XCTAssertTrue(html.contains("class=\"inline-link\"")) }
            if choice == .mention { XCTAssertTrue(html.contains("class=\"inline-link mention-link\"")) }
        }
    }
    @MainActor func testEditMenuSelectAllStaysInLinkFields() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        let original = "Links\n- [A long museum title that scrolls within the title field while editing](http://127.0.0.1:1/" + String(repeating: "review/", count: 16) + ")"
        try store.save(Note(text: original, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.inline-link') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        workspace.window?.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("showLinkMenu(document.querySelector('a.inline-link'));activeLinkMenu.querySelector('[data-link-action=edit]').click();")
        for field in ["title", "url"] {
            _ = try await view.callAsyncJavaScript("showLinkMenu(document.querySelector('a.inline-link'));activeLinkMenu.querySelector('[data-link-action=edit]').click();activeLinkMenu.querySelector('[data-link-field='+field+']').focus();", arguments: ["field": field], in: nil, contentWorld: .page)
            workspace.selectAllContent(nil)
            try await Task.sleep(nanoseconds: 30_000_000)
            let state = try await view.callAsyncJavaScript("const input=activeLinkMenu.querySelector('[data-link-field='+field+']');return [activeLinkMenu.classList.contains('open'),document.activeElement===input,input?.selectionStart,input?.selectionEnd,input?.value.length,source()];", arguments: ["field": field], in: nil, contentWorld: .page) as? [Any]
            let values = try XCTUnwrap(state)
            XCTAssertEqual(values[0] as? Bool, true)
            XCTAssertEqual(values[1] as? Bool, true)
            XCTAssertEqual(values[2] as? Int, 0)
            XCTAssertEqual(values[3] as? Int, values[4] as? Int)
            XCTAssertEqual(values[5] as? String, original)
        }
    }

    @MainActor func testSavingLinkReturnsCaretToNormalText() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        try store.save(Note(text: "Links\n- [A title](http://127.0.0.1:1/review)", language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.inline-link') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        window.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("showLinkMenu(document.querySelector('a.inline-link'));activeLinkMenu.querySelector('[data-link-action=edit]').click();activeLinkMenu.querySelector('[data-link-field=title]').value='Saved title';activeLinkMenu.querySelector('[data-link-action=save]').click();")
        let focused = try await view.evaluateJavaScript("!!document.activeElement.closest('.text')") as? Bool
        XCTAssertEqual(focused, true)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)))
        try await Task.sleep(nanoseconds: 50_000_000)
        let source = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(source, "Links\n- [Saved title](http://127.0.0.1:1/review)x")
        let outside = try await view.evaluateJavaScript("!getSelection().anchorNode.parentElement.closest('a')") as? Bool
        XCTAssertEqual(outside, true)
    }

    @MainActor func testEditMenuSelectAllStillWorksInRegularEditor() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "Ordinary text"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        workspace.window?.makeFirstResponder(workspace.editor)
        let delegate = AppDelegate(); delegate.workspace = workspace
        delegate.selectAllContent(nil)
        XCTAssertEqual(workspace.editor.selectedRange(), NSRange(location: 0, length: 13))
    }
    @MainActor func testSourceKeepsSlashCommandsLiteral() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        workspace.toggleMarkdownPreview()
        let editor = workspace.editor
        workspace.window?.makeFirstResponder(editor)
        editor.insertText("/h2", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(editor.slashMenuVisible)
        XCTAssertEqual(editor.string, "/h2")
        editor.insertNewline(nil)
        editor.insertText("/bullet", replacementRange: editor.selectedRange())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(editor.slashMenuVisible)
        XCTAssertEqual(editor.string, "/h2\n/bullet")
    }
}
