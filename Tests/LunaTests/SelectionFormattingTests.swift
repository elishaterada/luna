import AppKit
import XCTest
import LunaCore
@testable import Luna

final class SelectionFormattingTests: XCTestCase {
    @MainActor func testLinkTitleWithLiteralBacktickSurvivesReload() async throws {
        let original = "2. [Museum di`splay](https://example.com/)\n3. [Museum `display`](https://example.com/)"
        let workspace = try await fixture(original)
        let result = try await workspace.mediaView.evaluateJavaScript("[document.querySelectorAll('a.inline-link').length,source(),document.querySelectorAll('a.inline-link code').length]") as? [Any]
        XCTAssertEqual(result?[0] as? Int, 2)
        XCTAssertEqual(result?[1] as? String, original)
        XCTAssertEqual(result?[2] as? Int, 1)
    }

    @MainActor func testEditWrappedLinkKeepsFieldsOpenAfterFocus() async throws {
        let title = "Build a art museum featuring real art from sculpture to paintings that are legal to display"
        let original = "1. test\n2. [\(title)](https://example.com/)\nBusiness idea:"
        let workspace = try await fixture(original)
        let result = try await workspace.mediaView.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.style.width='320px';block.focus();
            const link=block.querySelector('a.inline-link');link.click();
            activeLinkMenu.querySelector('[data-link-action=edit]').click();
            await new Promise(resolve=>setTimeout(resolve,150));
            return [activeLinkMenu.classList.contains('open'),activeLink===link,
              document.activeElement===activeLinkMenu.querySelector('[data-link-field=title]'),
              activeLinkMenu.querySelector('[data-link-field=title]').value,
              activeLinkMenu.querySelector('[data-link-field=url]').value,source()];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true, "Edit Link must remain visible after the title input receives focus")
        XCTAssertEqual(result?[1] as? Bool, true)
        XCTAssertEqual(result?[2] as? Bool, true)
        XCTAssertEqual(result?[3] as? String, title)
        XCTAssertEqual(result?[4] as? String, "https://example.com/")
        XCTAssertEqual(result?[5] as? String, original)
    }

    @MainActor func testEditLinkIgnoresFieldScrollButDismissesForNoteScrollAndOutsideClick() async throws {
        let url = "https://example.com/" + String(repeating: "long-url-segment/", count: 8)
        let original = "- [Museum](\(url))"
        let workspace = try await fixture(original)
        let result = try await workspace.mediaView.callAsyncJavaScript("""
            const link=document.querySelector('a.inline-link');link.closest('.text').focus();link.click();
            activeLinkMenu.querySelector('[data-link-action=edit]').click();
            const url=activeLinkMenu.querySelector('[data-link-field=url]');url.focus();url.setSelectionRange(url.value.length,url.value.length);url.scrollLeft=url.scrollWidth;
            await new Promise(resolve=>setTimeout(resolve,150));
            const retained=activeLinkMenu.classList.contains('open')&&activeLink===link&&url.scrollLeft>0;
            const untouched=source();
            activeLinkMenu.querySelector('[data-link-field=title]').value='Updated museum';url.value='https://example.com/updated';
            activeLinkMenu.querySelector('[data-link-action=save]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            const saved=source();link.click();activeLinkMenu.querySelector('[data-link-action=edit]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            document.dispatchEvent(new Event('scroll'));
            const scrolled=!activeLinkMenu.classList.contains('open')&&activeLink===null;
            link.click();activeLinkMenu.querySelector('[data-link-action=edit]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            document.querySelector('.text').click();
            return [retained,untouched,saved,scrolled,!activeLinkMenu.classList.contains('open'),source()];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true, "Scrolling within the URL input must not dismiss editing")
        XCTAssertEqual(result?[1] as? String, original)
        let edited = "- [Updated museum](https://example.com/updated)"
        XCTAssertEqual(result?[2] as? String, edited)
        XCTAssertEqual(result?[3] as? Bool, true, "Scrolling the note still dismisses its anchored menu")
        XCTAssertEqual(result?[4] as? Bool, true)
        XCTAssertEqual(result?[5] as? String, edited)
    }

    @MainActor func testAddLinkFormSurvivesDeferredSelectionUpdates() async throws {
        let original = "1. test\n2. Build a art museum featuring real art from sculpture to paintings that are legal to display\nBusiness idea:"
        let workspace = try await fixture(original)
        let result = try await workspace.mediaView.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.focus();const node=block.querySelectorAll('.list-marker')[1].nextSibling;
            const range=document.createRange();range.setStart(node,1);range.setEnd(node,node.length);
            getSelection().removeAllRanges();getSelection().addRange(range);refreshSelectionUI();
            const button=formatMenu.querySelector('[data-format=link]');
            button.click();
            await new Promise(resolve=>setTimeout(resolve,100));refreshSelectionUI();
            const input=formatMenu.querySelector('input');
            return [!!input,formatMenu.classList.contains('open'),!!input&&document.activeElement===input,source(),selectionPaint.childElementCount>0];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true, "Clicking Add Link must leave the URL field visible after deferred UI refreshes")
        XCTAssertEqual(result?[1] as? Bool, true)
        XCTAssertEqual(result?[2] as? Bool, true)
        XCTAssertEqual(result?[3] as? String, original)
        XCTAssertEqual(result?[4] as? Bool, true, "The selected note content remains highlighted while editing the URL")
    }

    @MainActor func testLinkFormKeepsSavedListRangeThroughInputAndButtonFocus() async throws {
        let original = "1. Alpha\n2. Bravo museum"
        let workspace = try await fixture(original)
        let result = try await workspace.mediaView.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.focus();const node=block.querySelectorAll('.list-marker')[1].nextSibling;
            const range=document.createRange();range.setStart(node,7);range.setEnd(node,node.length);
            getSelection().removeAllRanges();getSelection().addRange(range);refreshSelectionUI();
            formatMenu.querySelector('[data-format=link]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            const input=formatMenu.querySelector('input');input.value='https://example.com/museum';input.select();
            input.dispatchEvent(new Event('input',{bubbles:true}));window.dispatchEvent(new Event('resize'));
            await new Promise(resolve=>setTimeout(resolve,100));
            const fieldSelection=document.activeElement===input&&input.selectionStart===0&&input.selectionEnd===input.value.length;
            formatMenu.querySelector('[type=submit]').focus();document.dispatchEvent(new Event('selectionchange'));
            await new Promise(resolve=>setTimeout(resolve,100));
            const retained=!!formatMenu.querySelector('input');
            const bounds=formatMenu.getBoundingClientRect(),visible=bounds.left>=0&&bounds.right<=innerWidth&&bounds.top>=0&&bounds.bottom<=innerHeight;
            formatMenu.querySelector('form').requestSubmit();
            await new Promise(resolve=>setTimeout(resolve,100));
            const linked=source();document.execCommand('undo');return [fieldSelection,retained,visible,linked,source()];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? Bool, true)
        XCTAssertEqual(result?[2] as? Bool, true, "The expanded form stays inside the viewport")
        XCTAssertEqual(result?[3] as? String, "1. Alpha\n2. Bravo [museum](https://example.com/museum)")
        XCTAssertEqual(result?[4] as? String, original)
    }

    @MainActor func testLinkFormCancelAndEscapeRestoreTextWithoutEditing() async throws {
        let original = "Hello museum world"
        let workspace = try await fixture(original)
        let result = try await workspace.mediaView.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.focus();const node=block.firstChild.firstChild;
            const range=document.createRange();range.setStart(node,6);range.setEnd(node,12);
            getSelection().removeAllRanges();getSelection().addRange(range);refreshSelectionUI();
            formatMenu.querySelector('[data-format=link]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            formatMenu.querySelector('input').value='https://example.com/unused';
            formatMenu.querySelector('[data-format=cancel-link]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            const cancelled=!formatMenu.querySelector('input')&&formatMenu.classList.contains('open')&&getSelection().toString()==='museum';
            formatMenu.querySelector('[data-format=link]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
            await new Promise(resolve=>setTimeout(resolve,100));
            return [cancelled,!formatMenu.classList.contains('open'),getSelection().toString(),source()];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? Bool, true)
        XCTAssertEqual(result?[2] as? String, "museum")
        XCTAssertEqual(result?[3] as? String, original)
    }

    @MainActor func testNativeTabNavigationStaysInLinkForm() async throws {
        let workspace = try await fixture("Museum")
        let view = workspace.mediaView, window = try XCTUnwrap(workspace.window)
        _ = try await view.callAsyncJavaScript("""
            document.querySelector('.text').focus();selectAllNote();refreshSelectionUI();
            formatMenu.querySelector('[data-format=link]').click();
            await new Promise(resolve=>setTimeout(resolve,100));
            """, in: nil, contentWorld: .page)
        func tab(_ flags: NSEvent.ModifierFlags = []) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)))
        }
        try tab()
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledFocus = try await view.evaluateJavaScript("document.activeElement.dataset.format==='cancel-link'") as? Bool
        XCTAssertEqual(cancelledFocus, true)
        try tab()
        try await Task.sleep(nanoseconds: 100_000_000)
        let saveFocus = try await view.evaluateJavaScript("document.activeElement.matches('#format-popover [type=submit]')") as? Bool
        XCTAssertEqual(saveFocus, true)
        try tab(.shift); try tab(.shift)
        try await Task.sleep(nanoseconds: 100_000_000)
        let result = try await view.evaluateJavaScript("[document.activeElement.id==='selection-link-url',formatMenu.classList.contains('open'),source()]") as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? Bool, true)
        XCTAssertEqual(result?[2] as? String, "Museum")
    }

    @MainActor private func fixture(_ text: String) async throws -> Workspace {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: text, language: "Markdown"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        addTeardownBlock { @MainActor in workspace.close(); try? FileManager.default.removeItem(at: root) }
        workspace.showWindow(nil)
        workspace.window?.makeKeyAndOrderFront(nil); workspace.window?.makeFirstResponder(workspace.mediaView)
        for _ in 0..<100 {
            if (try? await workspace.mediaView.evaluateJavaScript("typeof refreshSelectionUI")) as? String == "function" { return workspace }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Live editor did not load"); return workspace
    }

    @MainActor func testListSelectionHighlightsOnlyContentAndFormatsAcrossRows() async throws {
        let workspace = try await fixture("1. Alpha\n2. Bravo")
        let view = workspace.mediaView
        let result = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text'),rows=block.children;block.focus();
              const a=rows[0].querySelector('.list-marker').nextSibling,b=rows[1].querySelector('.list-marker').nextSibling;
              const range=document.createRange();range.setStart(rows[0],0);range.setEnd(b,b.length);
              getSelection().removeAllRanges();getSelection().addRange(range);refreshSelectionUI();
              const markers=[...block.querySelectorAll('.list-marker')].map(m=>m.getBoundingClientRect());
              const marks=[...selectionPaint.children].map(m=>m.getBoundingClientRect());
              const contentOnly=marks.length===2&&marks.every((r,i)=>r.left>=markers[i].right);
              const opened=formatMenu.classList.contains('open'),buttons=formatMenu.querySelectorAll('button').length;
              formatMenu.querySelector('[data-format=bold]').click();
              const formatted=source();document.execCommand('undo');const undone=source();document.execCommand('redo');
              return [contentOnly,opened,buttons,formatted,undone,source()];
            })()
            """) as? [Any]
        XCTAssertEqual(result?[0] as? Bool, true)
        XCTAssertEqual(result?[1] as? Bool, true)
        XCTAssertEqual(result?[2] as? Int, 5)
        XCTAssertEqual(result?[3] as? String, "1. **Alpha**\n2. **Bravo**")
        XCTAssertEqual(result?[4] as? String, "1. Alpha\n2. Bravo")
        XCTAssertEqual(result?[5] as? String, "1. **Alpha**\n2. **Bravo**")
        for _ in 0..<100 {
            if workspace.notes[workspace.index!].text == "1. **Alpha**\n2. **Bravo**" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try workspace.store.load().first?.text, "1. **Alpha**\n2. **Bravo**")
    }

    @MainActor func testInlineStylesRoundTripWithoutChangingOriginalMarkdown() async throws {
        let text = "**Bold** and _italic_ and ~~strike~~ and ``a`b`` and ***both***\n- **Bullet**\n`[Code](https://example.com)`\n**[Museum](https://example.com)**\n```\n**literal**\n```"
        let workspace = try await fixture(text)
        let result = try await workspace.mediaView.evaluateJavaScript("[source(),document.querySelectorAll('.text strong').length,document.querySelectorAll('.text code').length,document.querySelectorAll('.text a').length]") as? [Any]
        XCTAssertEqual(result?[0] as? String, text)
        XCTAssertEqual(result?[1] as? Int, 4)
        XCTAssertEqual(result?[2] as? Int, 2)
        XCTAssertEqual(result?[3] as? Int, 1, "Only the actual link, including its surrounding bold, should render")
    }

    @MainActor func testPartialFormattingAndLinkFieldsPreserveSelection() async throws {
        let workspace = try await fixture("Hello museum world")
        let result = try await workspace.mediaView.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text');block.focus();const text=block.firstChild.firstChild;
              const range=document.createRange();range.setStart(text,6);range.setEnd(text,12);
              getSelection().removeAllRanges();getSelection().addRange(range);refreshSelectionUI();
              applySelectionFormat('italic');const italic=source();document.execCommand('undo');
              const node=block.firstChild.firstChild,r=document.createRange();r.setStart(node,6);r.setEnd(node,12);
              getSelection().removeAllRanges();getSelection().addRange(r);refreshSelectionUI();
              formatMenu.querySelector('[data-format=link]').click();
              const input=formatMenu.querySelector('input');input.value='https://example.com/museum';
              input.select();const fieldsOwnSelection=document.activeElement===input&&input.selectionStart===0&&input.selectionEnd===input.value.length;
              formatMenu.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
              const linked=source();document.execCommand('undo');
              return [italic,fieldsOwnSelection,linked,source()];
            })()
            """) as? [Any]
        XCTAssertEqual(result?[0] as? String, "Hello *museum* world")
        XCTAssertEqual(result?[1] as? Bool, true)
        XCTAssertEqual(result?[2] as? String, "Hello [museum](https://example.com/museum) world")
        XCTAssertEqual(result?[3] as? String, "Hello museum world")
    }

    @MainActor func testInlineCodeKeepsListPrefixesAndUndo() async throws {
        let workspace = try await fixture("- Alpha\n- Bravo")
        let result = try await workspace.mediaView.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text'),markers=block.querySelectorAll('.list-marker');block.focus();
              const a=markers[0].nextSibling,b=markers[1].nextSibling,r=document.createRange();r.setStart(a,1);r.setEnd(b,b.length);
              getSelection().removeAllRanges();getSelection().addRange(r);refreshSelectionUI();applySelectionFormat('code');
              const formatted=source();document.execCommand('undo');return [formatted,source()];
            })()
            """) as? [String]
        XCTAssertEqual(result, ["- `Alpha`\n- `Bravo`", "- Alpha\n- Bravo"])
    }

    @MainActor func testToolbarDismissalKeyboardAccessAndCollapsedSelection() async throws {
        let workspace = try await fixture("Select this text")
        let result = try await workspace.mediaView.callAsyncJavaScript("""
            const block=document.querySelector('.text');block.focus();const node=block.firstChild.firstChild;
            const range=document.createRange();range.setStart(node,0);range.setEnd(node,6);
            getSelection().removeAllRanges();getSelection().addRange(range);refreshSelectionUI();
            const key=(key,options={})=>document.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true,...options}));
            key('F10',{altKey:true});const focused=document.activeElement.dataset.format==='bold';
            key('ArrowRight');const moved=document.activeElement.dataset.format==='italic';
            key('Escape');await new Promise(resolve=>setTimeout(resolve,100));refreshSelectionUI();
            const escaped=!formatMenu.classList.contains('open')&&!getSelection().isCollapsed;
            const r=getSelection().getRangeAt(0).cloneRange();r.setEnd(node,11);getSelection().removeAllRanges();getSelection().addRange(r);
            document.dispatchEvent(new Event('selectionchange'));refreshSelectionUI();const reopened=formatMenu.classList.contains('open');
            r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);refreshSelectionUI();
            return [focused,moved,escaped,reopened,!formatMenu.classList.contains('open'),selectionPaint.childElementCount===0];
            """, in: nil, contentWorld: .page) as? [Bool]
        XCTAssertEqual(result, [true, true, true, true, true, true])
    }

    @MainActor func testNativeFormattingShortcutAndTypingRemainUndoable() async throws {
        let workspace = try await fixture("Museum")
        let view = workspace.mediaView
        workspace.window?.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("document.querySelector('.text').focus();selectAllNote();refreshSelectionUI();")
        workspace.markdownBold()
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("source()")) as? String == "**Museum**" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.evaluateJavaScript("""
            (()=>{const bold=source();document.execCommand('undo');const undone=source();document.execCommand('redo');
              const block=document.querySelector('.text');block.focus();const text=block.querySelector('b,strong').firstChild;
              const r=document.createRange();r.setStart(text,text.length);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);
              document.execCommand('insertText',false,'s');return [bold,undone,source()];})()
            """) as? [String]
        XCTAssertEqual(result, ["**Museum**", "Museum", "**Museums**"])
    }

    @MainActor func testStyleTogglesPreserveBoundaryWhitespace() async throws {
        let workspace = try await fixture("Museum world")
        let result = try await workspace.mediaView.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text');block.focus();const node=block.firstChild.firstChild;
              const range=document.createRange();range.setStart(node,0);range.setEnd(node,7);
              getSelection().removeAllRanges();getSelection().addRange(range);refreshSelectionUI();
              applySelectionFormat('bold');const bold=source();applySelectionFormat('bold');const plain=source();
              applySelectionFormat('strikeThrough');const strike=source();applySelectionFormat('strikeThrough');
              applySelectionFormat('code');const code=source();
              const element=block.querySelector('code,span[style*="ui-monospace"]'),r=document.createRange();r.selectNodeContents(element);
              getSelection().removeAllRanges();getSelection().addRange(r);refreshSelectionUI();applySelectionFormat('code');
              return [bold,plain,strike,code,source()];
            })()
            """) as? [String]
        XCTAssertEqual(result, ["**Museum** world", "Museum world", "~~Museum ~~world", "`Museum `world", "Museum world"])
    }

    @MainActor func testLinkFormattingAcrossListRowsKeepsMarkersOutsideLinks() async throws {
        let workspace = try await fixture("1. Alpha\n2. Bravo")
        let result = try await workspace.mediaView.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text');block.focus();selectAllNote();refreshSelectionUI();
              formatMenu.querySelector('[data-format=link]').click();formatMenu.querySelector('input').value='https://example.com/museum';
              formatMenu.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
              const formatted=source();document.execCommand('undo');return [formatted,source()];
            })()
            """) as? [String]
        XCTAssertEqual(result, ["1. [Alpha](https://example.com/museum)\n2. [Bravo](https://example.com/museum)", "1. Alpha\n2. Bravo"])
    }
}
