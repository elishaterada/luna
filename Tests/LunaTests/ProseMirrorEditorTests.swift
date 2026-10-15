import AppKit
import WebKit
import XCTest
import LunaCore
@testable import Luna

/// Exercise the same document/command interface used by the native adapter.
/// Native key cases also cross WKWebView's responder and editing integration.
final class ProseMirrorEditorTests: XCTestCase {
    @MainActor private func workspace(_ source: String) async throws -> Workspace {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: source, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        addTeardownBlock { @MainActor in workspace.close(); try? FileManager.default.removeItem(at: root) }
        workspace.showWindow(nil)
        for _ in 0..<100 {
            if (try? await workspace.mediaView.evaluateJavaScript("!!window.lunaEditor?.view")) as? Bool == true { return workspace }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("ProseMirror did not become ready"); return workspace
    }
    @MainActor private func js(_ code: String, _ workspace: Workspace) async throws -> Any? {
        try await workspace.mediaView.callAsyncJavaScript(code, in: nil, contentWorld: .page)
    }
    @MainActor private func source(_ workspace: Workspace) async throws -> String {
        let value = try await workspace.mediaView.evaluateJavaScript("window.lunaEditor.source") as? String
        return try XCTUnwrap(value)
    }
    @MainActor private func select(_ from: Int, _ workspace: Workspace) async throws { try await select(from, from, workspace) }
    @MainActor private func select(_ from: Int, _ to: Int?, _ workspace: Workspace) async throws {
        _ = try await js("window.lunaEditor.select(\(from),\(to ?? from));window.lunaEditor.focus();", workspace)
        workspace.window?.makeFirstResponder(workspace.mediaView)
    }
    @MainActor private func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], _ workspace: Workspace) async throws {
        let window = try XCTUnwrap(workspace.window)
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        let focused = window.firstResponder as? NSView
        if focused !== workspace.mediaView && focused?.isDescendant(of: workspace.mediaView) != true { window.makeFirstResponder(workspace.mediaView) }
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        try await Task.sleep(nanoseconds: 70_000_000)
    }
    @MainActor private func waitForModel(_ predicate: String, _ workspace: Workspace) async throws {
        for _ in 0..<200 {
            if (try await js("return " + predicate, workspace)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let state = try await js("return JSON.stringify(lunaEditor.state)", workspace)
        XCTFail("Native input did not reach expected model: \(predicate); state: \(String(describing: state))")
    }
    @MainActor private func eventually(_ expected: String, _ workspace: Workspace) async throws {
        for _ in 0..<80 { if workspace.editor.string == expected { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        let actual = try await source(workspace); XCTAssertEqual(actual, expected); XCTAssertEqual(workspace.editor.string, expected)
    }

    @MainActor func testOpeningAndSourceSwitchingPreserveExactMarkdown() async throws {
        let cases = ["Updates:\n- Filipino dish\n- ","* one\n* two\n\n+ other\n", "Before\n\n\nAfter\n\n", "[Preview](https://example.com)\n\n**bold** *italic* `code` ~~strike~~", "☐ old task\n☑ completed", "- [ ] task\n- [x] done", "```html\n<script>bad()</script>\n```", "[a\\`b](https://example.com)"]
        for original in cases {
            let workspace = try await workspace(original)
            let loaded = try await source(workspace); XCTAssertEqual(loaded, original)
            workspace.toggleMarkdownPreview(); XCTAssertEqual(workspace.editor.string, original)
            workspace.toggleMarkdownPreview()
            for _ in 0..<100 { if (try? await workspace.mediaView.evaluateJavaScript("!!window.lunaEditor?.view")) as? Bool == true { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            let reopened = try await source(workspace); XCTAssertEqual(reopened, original)
            XCTAssertTrue(workspace.flushRecovery()); XCTAssertEqual(try workspace.store.load().first?.text, original)
        }
    }
    @MainActor func testEditingPreservesUntouchedBlocksAndBulletIdentity() async throws {
        let original = "# Heading\n\n* first\n* second\n\n[Preview](https://example.com)\n\nTail\n"
        let workspace = try await workspace(original)
        _ = try await js("let v=lunaEditor.view,p=0;v.state.doc.descendants((n,pos)=>{if(n.isText&&n.text==='Tail')p=pos+4});lunaEditor.select(p);lunaEditor.command('pastePlainText','!');", workspace)
        try await eventually(original.replacingOccurrences(of: "Tail", with: "Tail!"), workspace)
        _ = try await js("lunaEditor.command('undo')", workspace)
        try await eventually(original, workspace)
    }
    @MainActor func testNativeLeftFromEmptyBulletAndContinuedTyping() async throws {
        let workspace = try await workspace("Updates:\n- Filipino dish\n- ")
        _ = try await js("let p=0;lunaEditor.view.state.doc.descendants((n,pos)=>{if(n.type.name==='list_item')p=pos+2});lunaEditor.select(p);lunaEditor.focus();", workspace)
        try await key("\u{F702}", code: 123, workspace)
        try await key("!", code: 18, workspace)
        try await eventually("Updates:\n- Filipino dish!\n- ", workspace)
        try await key("z", code: 6, flags: .command, workspace)
        try await eventually("Updates:\n- Filipino dish\n- ", workspace)
    }
    @MainActor func testNativeListContinuationExitAndPrefixBackspace() async throws {
        let workspace = try await workspace("- A")
        try await select(4, workspace)
        try await key("\r", code: 36, workspace)
        try await eventually("- A\n- ", workspace)
        try await key("\u{7f}", code: 51, workspace)
        try await key("B", code: 11, workspace)
        try await eventually("- A\nB", workspace)
    }
    @MainActor func testNativeNumberedListAndBulletInputRules() async throws {
        let workspace = try await workspace("")
        try await select(1, workspace)
        try await key("1", workspace); try await waitForModel("lunaEditor.view.state.doc.textContent === '1'", workspace)
        try await key(".", workspace); try await waitForModel("lunaEditor.view.state.doc.textContent === '1.'", workspace)
        try await key(" ", workspace); try await waitForModel("lunaEditor.view.state.doc.firstChild.type.name === 'ordered_list'", workspace)
        var typed = ""
        for c in "test" {
            try await key(String(c), workspace); typed += String(c)
            try await waitForModel("lunaEditor.view.state.doc.textContent === '\(typed)'", workspace)
        }
        try await key("\r", code: 36, workspace)
        try await waitForModel("lunaEditor.view.state.doc.firstChild.childCount === 2", workspace)
        for c in "next" {
            try await key(String(c), workspace); typed += String(c)
            try await waitForModel("lunaEditor.view.state.doc.textContent === '\(typed)'", workspace)
        }
        try await eventually("1. test\n2. next", workspace)
    }
    @MainActor func testSelectedListIndentOutdentAndAtomicUndo() async throws {
        let workspace = try await workspace("- A\n- B\n- C")
        _ = try await js("const positions=[];lunaEditor.view.state.doc.descendants((n,p)=>{if(n.type.name==='list_item')positions.push(p+2)});lunaEditor.select(positions[1],positions[2]+1);lunaEditor.command('indent');", workspace)
        let indented = try await source(workspace); XCTAssertEqual(indented, "- A\n  - B\n  - C")
        _ = try await js("lunaEditor.command('undo')", workspace)
        try await eventually("- A\n- B\n- C", workspace)
    }
    @MainActor func testWholeNoteReplacementUndoRedoRestoresRichBlocks() async throws {
        for original in ["Before\n[Bookmark](https://example.com)\nAfter", "[Bookmark](https://example.com)\n\n- List"] {
            let workspace = try await workspace(original)
            let cards=try await js("return document.querySelectorAll('.luna-card').length",workspace) as? Int;XCTAssertEqual(cards,1)
            _ = try await js("lunaEditor.command('selectAll');lunaEditor.command('pastePlainText','replacement');", workspace)
            try await eventually("replacement", workspace)
            _ = try await js("lunaEditor.command('undo')", workspace); try await eventually(original, workspace)
            _ = try await js("lunaEditor.command('redo')", workspace); try await eventually("replacement", workspace)
        }
    }
    @MainActor func testNativeSelectAllReplacementAndHistoryRouting() async throws {
        let original = "Before\n[Bookmark](https://example.com)\nAfter"
        let workspace = try await workspace(original); try await select(1, workspace)
        try await key("a", code: 0, flags: .command, workspace)
        // Deliver a native word in one event batch. Runner scheduling between
        // awaited letters must not turn one word into several history groups.
        let window = try XCTUnwrap(workspace.window)
        for c in "word" {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: String(c), charactersIgnoringModifiers: String(c), isARepeat: false, keyCode: 0)))
        }
        try await eventually("word", workspace)
        try await key("z", code: 6, flags: .command, workspace); try await eventually(original, workspace)
        try await key("z", code: 6, flags: [.command,.shift], workspace); try await eventually("word", workspace)
    }
    @MainActor func testPlainPasteRemainsLiteralAndPersists() async throws {
        let workspace = try await workspace("Before selected after");try await select(8,16,workspace)
        _ = try await js("lunaEditor.command('pastePlainText', 'https://example.com\\n<iframe src=\"https://example.com\"></iframe>\\n🌙')",workspace)
        let expected="Before https://example.com\n<iframe src=\"https://example.com\"></iframe>\n🌙 after"
        try await eventually(expected,workspace)
        let rich = try await js("return !!document.querySelector('iframe,a[data-prototype-link]')",workspace) as? Bool;XCTAssertEqual(rich,false)
        XCTAssertTrue(workspace.flushRecovery());XCTAssertEqual(try workspace.store.load().first?.text,expected)
        _ = try await js("lunaEditor.command('undo')",workspace);try await eventually("Before selected after",workspace)
    }
    @MainActor func testURLPasteDisplayConversionsAndUndo() async throws {
        for (display,label) in [("mention","Mention"),("bookmark","Bookmark"),("embed","Embed"),("linked","URL"),("plain","")] {
            let workspace=try await workspace("");try await select(1,workspace)
            _ = try await js("lunaEditor.insertSnippet('https://example.com/path',true);document.querySelector('[data-display=\(display)]').click()",workspace)
            let changed=try await source(workspace)
            XCTAssertTrue(changed.contains(label.isEmpty ? "https://example.com/path" : "[\(label)](https://example.com/path)"),changed)
            _ = try await js("lunaEditor.command('pastePlainText','!');lunaEditor.command('undo')",workspace)
            let undoneTyping=try await source(workspace);XCTAssertEqual(undoneTyping,changed)
            if !["linked","plain"].contains(display) {
                _ = try await js("lunaEditor.command('undo')",workspace)
                let undone=try await source(workspace);XCTAssertTrue(undone.contains("[URL]"),undone)
                _ = try await js("lunaEditor.command('redo')",workspace);let redone=try await source(workspace);XCTAssertEqual(redone,changed)
            }
        }
    }
    @MainActor func testDisplayConversionRetainsSurroundingHeadingAndListText() async throws {
        for original in ["Before after","# Before after","- Before after"] {
            let workspace=try await workspace(original)
            _ = try await js("let p=0;lunaEditor.view.state.doc.descendants((n,pos)=>{if(n.isText)p=pos+7});lunaEditor.select(p);lunaEditor.insertSnippet('https://example.com',true);document.querySelector('[data-display=bookmark]').click();",workspace)
            let changed=try await source(workspace);XCTAssertTrue(changed.contains("Before"));XCTAssertTrue(changed.contains("after"));XCTAssertTrue(changed.contains("[Bookmark]"))
        }
    }
    @MainActor func testMetadataDoesNotEditSelectionSourceOrHistory() async throws {
        let original="[Mention](https://example.com/)\n\n[Bookmark](https://example.com/)"
        let workspace=try await workspace(original)
        let result=try await js("const before=[lunaEditor.source,JSON.stringify(lunaEditor.state.selection),JSON.stringify(lunaEditor.history)];lunaEditor.resolve(lunaEditor.session,'https://example.com/',{title:'Resolved title',description:'Description'});return [before,[lunaEditor.source,JSON.stringify(lunaEditor.state.selection),JSON.stringify(lunaEditor.history)],document.body.textContent.includes('Resolved title')];",workspace) as? [Any]
        XCTAssertEqual(result?[0] as? [String],result?[1] as? [String]);XCTAssertEqual(result?[2] as? Bool,true)
    }
    @MainActor func testEditLinkFieldsSelectAllTabSaveAndContinuedTyping() async throws {
        let workspace=try await workspace("Before [Title](https://example.com) after")
        _ = try await js("lunaEditor.select(10);lunaEditor.command('showLink');[...document.querySelectorAll('#link-popover button')].find(b=>b.textContent==='Edit link').click();lunaEditor.command('selectAll');",workspace)
        let selected=try await js("return document.activeElement.selectionEnd-document.activeElement.selectionStart",workspace) as? Int;XCTAssertEqual(selected,5)
        _ = try await js("const form=document.querySelector('#link-popover form');form.querySelector('input').value='New title';form.querySelector('input[type=url]').value='https://example.com/new';form.requestSubmit();",workspace)
        try await key("!",code:18,workspace)
        let changed=try await source(workspace);XCTAssertEqual(changed,"Before [New title](https://example.com/new)! after")
    }
    @MainActor func testSelectionFormattingAndLinkFormRetainModelRange() async throws {
        let workspace=try await workspace("Before selected after");try await select(8,16,workspace)
        _ = try await js("lunaEditor.command('bold');lunaEditor.command('italic');lunaEditor.command('strike');lunaEditor.command('link');",workspace)
        try await Task.sleep(nanoseconds:200_000_000)
        let visible=try await js("return !document.getElementById('selection-toolbar').hidden&&document.activeElement.type==='url'",workspace) as? Bool;XCTAssertEqual(visible,true)
        _ = try await js("document.activeElement.value='https://example.com';document.activeElement.form.requestSubmit();",workspace)
        let result=try await source(workspace);XCTAssertTrue(result.contains("**"),result);XCTAssertTrue(result.contains("~~"),result);XCTAssertTrue(result.contains("https://example.com"),result);XCTAssertTrue(result.hasPrefix("Before "));XCTAssertTrue(result.hasSuffix(" after"))
    }
    @MainActor func testSlashSearchKeyboardChoiceAndUndo() async throws {
        let workspace=try await workspace("");try await select(1,workspace)
        for c in "/h2" {try await key(String(c),workspace)}
        let label=try await js("return document.querySelector('#slash-menu button')?.textContent",workspace) as? String;XCTAssertEqual(label,"Heading 2")
        try await key("\r",code:36,workspace);try await key("H",workspace)
        try await eventually("## H",workspace)
        _ = try await js("lunaEditor.command('undo');lunaEditor.command('undo')",workspace)
        let undone=try await source(workspace);XCTAssertEqual(undone,"/h2")
    }
    @MainActor func testTaskToggleIsUndoableAndLegacyTasksRemainPortable() async throws {
        for original in ["- [ ] Task\n- [x] Done","☐ Task\n☑ Done"] {
            let workspace=try await workspace(original)
            let count=try await js("return document.querySelectorAll('input[type=checkbox]').length",workspace) as? Int;XCTAssertEqual(count,2)
            _ = try await js("document.querySelector('input[type=checkbox]').click()",workspace)
            let changed=try await source(workspace);XCTAssertTrue(changed.contains(original.hasPrefix("☐") ? "☑ Task" : "[x] Task"),changed)
            _ = try await js("lunaEditor.command('undo')",workspace);try await eventually(original,workspace)
        }
    }
    @MainActor func testBlankRowsAreNavigableAndTypingUsesNativeCaret() async throws {
        let workspace=try await workspace("A\n\n\nB");try await select(2,workspace)
        try await key("\u{F701}",code:125,workspace);try await key("!",code:18,workspace)
        try await eventually("A\n!\n\nB",workspace)
        let native=try await js("return !document.querySelector('#text-caret')&&getComputedStyle(document.querySelector('.ProseMirror')).caretColor!=='rgba(0, 0, 0, 0)'",workspace) as? Bool;XCTAssertEqual(native,true)
    }
    @MainActor func testThemeAndSizeChangeKeepSelectionAndUndo() async throws {
        let workspace=try await workspace("Text");try await select(5,workspace)
        _ = try await js("lunaEditor.command('pastePlainText','!');lunaEditor.theme(false,30);",workspace)
        let result=try await js("return [lunaEditor.source,lunaEditor.state.selection.head,getComputedStyle(document.querySelector('.ProseMirror')).fontSize]",workspace) as? [Any]
        XCTAssertEqual(result?[0] as? String,"Text!");XCTAssertEqual(result?[1] as? Int,6);XCTAssertEqual(result?[2] as? String,"30px")
        _ = try await js("lunaEditor.command('undo')",workspace);try await eventually("Text",workspace)
    }
    @MainActor func testImmediateNewNotePasteAndQueuedTyping() async throws {
        let workspace=try await workspace("Original");workspace.newNote()
        for c in "First" {try await key(String(c),workspace)}
        try await eventually("First",workspace)
        workspace.newNote();workspace.mediaView.command("pastePlainText",text:"https://example.com")
        try await eventually("https://example.com",workspace)
    }
    @MainActor func testImportedMediaWhileLoadingAndRepeatedImportsAreUndoable() async throws {
        let workspace=try await workspace("");workspace.newNote()
        let file=try XCTUnwrap(Bundle.module.url(forResource:"skin",withExtension:"mp4",subdirectory:"Fixtures"))
        workspace.importMedia([file])
        for _ in 0..<200 {if (try? await js("return document.querySelectorAll('video').length",workspace)) as? Int == 1 {break};try await Task.sleep(nanoseconds:30_000_000)}
        let count=try await js("return document.querySelectorAll('video').length",workspace) as? Int;XCTAssertEqual(count,1)
        for _ in 0..<100 {if (try? await js("return document.querySelector('video')?.readyState>0",workspace)) as? Bool == true {break};try await Task.sleep(nanoseconds:30_000_000)}
        let loaded=try await js("return document.querySelector('video')?.readyState>0",workspace) as? Bool;XCTAssertEqual(loaded,true)
        workspace.importMedia([file]);for _ in 0..<200 {if (try? await js("return document.querySelectorAll('video').length",workspace)) as? Int == 2 {break};try await Task.sleep(nanoseconds:30_000_000)}
        let count2=try await js("return document.querySelectorAll('video').length",workspace) as? Int;XCTAssertEqual(count2,2)
        _ = try await js("lunaEditor.command('undo')",workspace);let count3=try await js("return document.querySelectorAll('video').length",workspace) as? Int;XCTAssertEqual(count3,1)
        XCTAssertTrue(workspace.flushRecovery());XCTAssertEqual(try workspace.store.load().first?.text,workspace.editor.string)
    }
    @MainActor func testCodePasteAndUntrustedHTMLStayLiteral() async throws {
        let workspace=try await workspace("```\ncode\n```")
        try await select(5,workspace)
        _ = try await js("lunaEditor.insertSnippet('https://example.com',true)",workspace)
        let anchors=try await js("return document.querySelectorAll('a,iframe').length",workspace) as? Int;XCTAssertEqual(anchors,0)
        let html=try await self.workspace("<script>window.injected=true</script>\n<iframe src='javascript:bad()'></iframe>")
        let injected=try await js("return !!window.injected||!!document.querySelector('iframe')",html) as? Bool;XCTAssertEqual(injected,false)
    }
    @MainActor func testRapidSelectAllTypingAndUndoPreservePreviousWriting() async throws {
        let original="Before\n[Bookmark](https://example.com)\nAfter"
        let workspace=try await workspace(original)
        _ = try await js("lunaEditor.select(lunaEditor.view.state.doc.content.size-1);lunaEditor.command('pastePlainText',' edited');",workspace)
        let window=try XCTUnwrap(workspace.window);window.makeFirstResponder(workspace.mediaView)
        func send(_ text:String,_ code:UInt16,_ flags:NSEvent.ModifierFlags=[]) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)))
        }
        try send("a",0,.command)
        for c in "replacement" {try send(String(c),0)}
        try await eventually("replacement",workspace)
        try send("z",6,.command)
        try await eventually(original+" edited",workspace)
    }
    @MainActor func testListExitReopensAsProseAndLegacyBulletsRemainLists() async throws {
        let original="Updates:\n12. First\n13. Second\nOrdinary prose\n• Legacy bullet"
        let workspace=try await workspace(original)
        let result=try await js("return lunaEditor.state.document.content.map(n=>n.type)",workspace) as? [String]
        XCTAssertEqual(result,["paragraph","ordered_list","paragraph","bullet_list"])
        let loaded=try await source(workspace);XCTAssertEqual(loaded,original)
    }
    @MainActor func testTypedBulletMarkersAndTaskContinuation() async throws {
        for marker in ["*","+","•"] {
            let workspace=try await workspace("");try await select(1,workspace)
            for c in marker+" One" {try await key(String(c),workspace)}
            try await key("\r",code:36,workspace);try await key("B",workspace)
            try await eventually(marker+" One\n"+marker+" B",workspace)
        }
        let workspace=try await workspace("- [x] Completed");try await select(12,workspace)
        try await key("\r",code:36,workspace);try await key("N",workspace)
        let result=try await source(workspace);XCTAssertEqual(result,"- [x] Completed\n- [ ] N")
    }
    @MainActor func testEverySlashCommandCreatesTheIntendedModelBlock() async throws {
        let cases=[("Text","paragraph"),("Heading 1","heading"),("Heading 2","heading"),("Quote","blockquote"),("Bulleted list","bullet_list"),("Numbered list","ordered_list"),("To-do list","bullet_list"),("Code block","code_block"),("Divider","horizontal_rule")]
        for (title,type) in cases {
            let workspace=try await workspace("/");try await select(2,workspace)
            _ = try await workspace.mediaView.callAsyncJavaScript("[...document.querySelectorAll('#slash-menu button')].find(button=>button.textContent===title).click()",arguments:["title":title],in:nil,contentWorld:.page)
            let actual=try await js("return lunaEditor.state.document.content[0].type",workspace) as? String;XCTAssertEqual(actual,type,title)
            if title=="To-do list" {let task=try await js("return document.querySelectorAll('input[type=checkbox]').length",workspace) as? Int;XCTAssertEqual(task,1)}
        }
    }

    @MainActor func testPendingEditsFinishBeforeNewNoteAndSourceSwitch() async throws {
        let workspace=try await workspace("Original")
        let originalID=try XCTUnwrap(workspace.selectedID)
        workspace.mediaView.selectAllNote();workspace.mediaView.command("pastePlainText",text:"Replacement")
        workspace.newNote()
        for _ in 0..<100 {if workspace.selectedID != originalID {break};try await Task.sleep(nanoseconds:25_000_000)}
        XCTAssertNotEqual(workspace.selectedID,originalID)
        XCTAssertEqual(workspace.notes.first(where:{$0.id==originalID})?.text,"Replacement")
        XCTAssertEqual(try workspace.store.load().first(where:{$0.id==originalID})?.text,"Replacement")
        workspace.mediaView.command("pastePlainText",text:"New writing")
        workspace.toggleMarkdownPreview()
        for _ in 0..<100 {if !workspace.richEditing {break};try await Task.sleep(nanoseconds:25_000_000)}
        XCTAssertFalse(workspace.richEditing);XCTAssertEqual(workspace.editor.string,"New writing")
    }
    @MainActor func testFinalSnapshotFlushesQueuedCommandsForTermination() async throws {
        let workspace=try await workspace("Original")
        workspace.mediaView.selectAllNote();workspace.mediaView.command("pastePlainText",text:"Final writing")
        let ready=await workspace.flushLiveChanges();XCTAssertTrue(ready)
        XCTAssertTrue(workspace.flushAllRecovery());XCTAssertEqual(try workspace.store.load().first?.text,"Final writing")
    }

    @MainActor func testRichBlocksReopenWithoutRequiringBlankSourceLines() async throws {
        let original="Before\n[Bookmark](https://example.com)\nAfter\n[Embed](https://example.com/player)\nEnd"
        let workspace=try await workspace(original)
        let count=try await js("return document.querySelectorAll('.luna-card').length",workspace) as? Int;XCTAssertEqual(count,2)
        _ = try await js("lunaEditor.select(lunaEditor.view.state.doc.content.size-1);lunaEditor.command('pastePlainText','!')",workspace)
        let changed=try await source(workspace);XCTAssertEqual(changed,original+"!")
        workspace.toggleMarkdownPreview();workspace.toggleMarkdownPreview()
        for _ in 0..<100 {if (try? await workspace.mediaView.evaluateJavaScript("document.querySelectorAll('.luna-card').length")) as? Int == 2 {break};try await Task.sleep(nanoseconds:25_000_000)}
        let reopened=try await js("return document.querySelectorAll('.luna-card').length",workspace) as? Int;XCTAssertEqual(reopened,2)
    }
    @MainActor func testReferenceDefinitionsSurviveEditingAnotherBlock() async throws {
        let original="[Label][site]\n\n[site]: https://example.com\n\nTail"
        let workspace=try await workspace(original)
        _ = try await js("lunaEditor.select(lunaEditor.view.state.doc.content.size-1);lunaEditor.command('pastePlainText','!')",workspace)
        let changed=try await source(workspace);XCTAssertEqual(changed,original+"!")
    }

    @MainActor func testWhitespaceOnlyNoteKeepsEveryWritingRowAfterEditing() async throws {
        let workspace=try await workspace("\n\n");try await select(1,workspace)
        let count=try await js("return lunaEditor.state.counts.paragraph",workspace) as? Int;XCTAssertEqual(count,3)
        _ = try await js("lunaEditor.command('pastePlainText','A')",workspace)
        try await eventually("A\n\n",workspace)
    }
    @MainActor func testExistingURLDisplayConventionSurvivesEditingItsParagraph() async throws {
        let workspace=try await workspace("[URL](https://example.com)")
        _ = try await js("lunaEditor.select(lunaEditor.view.state.doc.content.size-1);lunaEditor.command('pastePlainText','!')",workspace)
        let changed=try await source(workspace);XCTAssertEqual(changed,"[URL](https://example.com/)!")
    }

    @MainActor func testRapidSelectAllURLPasteRemainsOrderedAndOpensChoices() async throws {
        let workspace=try await workspace("Before\n[Bookmark](https://example.com)\nAfter")
        workspace.mediaView.selectAllNote();workspace.mediaView.command("paste",text:"https://example.com/new")
        try await eventually("[URL](https://example.com/new)",workspace)
        let open=try await js("return !document.getElementById('link-popover').hidden",workspace) as? Bool;XCTAssertEqual(open,true)
    }

    @MainActor func testBlankRowsAfterAListRemainVisibleAndNavigable() async throws {
        let workspace=try await workspace("- A\n\n\nB");try await select(4,workspace)
        let count=try await js("return lunaEditor.state.document.content.filter(node=>node.type==='paragraph'&&!node.content).length",workspace) as? Int;XCTAssertEqual(count,2)
        try await key("\u{F701}",code:125,workspace);try await key("!",code:18,workspace)
        try await eventually("- A\n!\n\nB",workspace)
    }

}
