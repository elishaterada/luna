import AppKit
import WebKit
import XCTest
import LunaCore
@testable import Luna

final class NoteEmbedsTests: XCTestCase {
    func testEmbedParsingEscapesScriptsAndRespectsCodeBlocks() throws {
        let snippet = try XCTUnwrap(NoteEmbeds.insertion("<iframe src='https://example.com/embed?a=1&amp;b=2' onload='bad()'></iframe>"))
        XCTAssertEqual(snippet, "\n[Embed](https://example.com/embed?a=1&b=2)\n")
        XCTAssertNil(NoteEmbeds.insertion("<iframe src='javascript:alert(1)'></iframe>"))
        XCTAssertNil(NoteEmbeds.insertion("file:///private/secret"))
        XCTAssertFalse(NoteEmbeds.hasContent("```html\nhttps://example.com\n```"))
        let source = "Before\n\n" + snippet + "\nAfter"
        XCTAssertEqual(NoteEmbeds.blocks(source).map(\.source).joined(separator: "\n"), source)
        let page = MediaNoteView.page(Note(text: source + "\n<script>bad()</script>"), fontSize: 18, dark: true, pageID: "test")
        XCTAssertTrue(page.contains("sandbox=\"allow-scripts allow-same-origin allow-presentation\""))
        XCTAssertFalse(page.contains("<script>bad()"))
        XCTAssertTrue(page.contains("&lt;script&gt;bad()&lt;/script&gt;"))
        XCTAssertTrue(page.contains("contenteditable=\"true\""))
    }
    func testOEmbedUsesOnlySafeProviderURLs() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "video", "html": "<iframe src=\"https://player.example.com/123\" onload=\"bad()\"></iframe><script>bad()</script>"])
        XCTAssertEqual(EmbedResolver.responseURL(data)?.absoluteString, "https://player.example.com/123")
        XCTAssertNil(EmbedResolver.responseURL(try JSONSerialization.data(withJSONObject: ["type": "video", "html": "<script>bad()</script>"])))
    }
    @MainActor func testRichNoteLinkAlignsWithEditorLeftInset() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "[URL](https://example.com)"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.inline-link') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let alignment = try await view.evaluateJavaScript("""
            document.body.style.width='1400px';
            const article=document.querySelector('article');
            JSON.stringify({left:Math.round(article.getBoundingClientRect().left),
              inset:parseInt(getComputedStyle(document.body).paddingLeft),
              linkLeft:Math.round(document.querySelector('a.inline-link').getBoundingClientRect().left)});
            """) as? String
        XCTAssertEqual(alignment, "{\"left\":40,\"inset\":40,\"linkLeft\":40}")
    }
    @MainActor func testPastedURLStaysInlineAndCanBeEditedOrRestyled() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "Before [URL](https://example.com) After"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('a.inline-link').length")) as? Int == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let rendered = try await view.evaluateJavaScript("document.querySelector('.text').innerText") as? String
        XCTAssertEqual(rendered, "Before https://example.com After")
        _ = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const range=document.createRange();range.setStart(block.firstChild,7);range.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(range);
            window.webkit.messageHandlers.note.postMessage({page,kind:'paste',value:'https://example.org/path'});
            true
            """)
        for _ in 0..<100 {
            if workspace.editor.string.contains("[URL](https://example.org/path)"),
               (try? await view.evaluateJavaScript("document.getElementById('link-popover').classList.contains('open')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, "Before [URL](https://example.org/path)[URL](https://example.com) After")
        let fitsToRight = try await view.evaluateJavaScript("""
            const menu=document.getElementById('link-popover');
            const right=innerWidth-128;
            positionPopover(menu,{left:right-40,right,top:70,bottom:90});
            const box=menu.getBoundingClientRect();
            box.left>=right+5 && box.right<=innerWidth-7 && box.width<=114 && getComputedStyle(menu).fontSize==='11px'
            """) as? Bool
        XCTAssertEqual(fitsToRight, true, "Display choices should shrink and stay to the right when only 114 points remain")
        let inlineCount = try await view.evaluateJavaScript("document.querySelectorAll('.text a.inline-link').length") as? Int
        let figureCount = try await view.evaluateJavaScript("document.querySelectorAll('figure[data-url]').length") as? Int
        XCTAssertEqual(inlineCount, 2)
        XCTAssertEqual(figureCount, 0)
        _ = try await view.evaluateJavaScript("document.querySelector('.text').click();true")
        let popoverClosed = try await view.evaluateJavaScript("document.getElementById('link-popover').classList.contains('open')") as? Bool
        XCTAssertEqual(popoverClosed, false)
        _ = try await view.evaluateJavaScript("document.querySelector('a.inline-link[data-url=\"https://example.org/path\"]').click();true")
        _ = try await view.evaluateJavaScript("document.querySelector('[data-link-action=styles]').click();document.querySelector('[data-link-action=linked]').click();true")
        let linkedChoiceClosed = try await view.evaluateJavaScript("document.getElementById('link-popover').classList.contains('open')") as? Bool
        XCTAssertEqual(linkedChoiceClosed, false)
        XCTAssertEqual(workspace.editor.string, "Before [URL](https://example.org/path)[URL](https://example.com) After")
        _ = try await view.evaluateJavaScript("document.querySelector('a.inline-link[data-url=\"https://example.org/path\"]').click();true")
        _ = try await view.evaluateJavaScript("document.querySelector('[data-link-action=edit]').click();true")
        _ = try await view.evaluateJavaScript("""
            document.querySelector('[data-link-field=title]').value='Suno list';
            document.querySelector('[data-link-field=url]').value='https://example.org/updated';
            document.querySelector('[data-link-action=save]').click();true
            """)
        let editedSource = try await view.evaluateJavaScript("source()") as? String
        let menuState = try await view.evaluateJavaScript("document.getElementById('link-popover').innerHTML + ' / ' + document.querySelector('[data-link-field=url]')?.validationMessage + ' / ' + activeLink?.dataset.url") as? String
        XCTAssertTrue(workspace.editor.string.contains("[Suno list](https://example.org/updated)"), "\(workspace.editor.string) / \(editedSource ?? "nil") / \(menuState ?? "nil")")
        _ = try await view.evaluateJavaScript("document.querySelector('a.inline-link[data-url=\"https://example.org/updated\"]').click();document.querySelector('[data-link-action=styles]').click();document.querySelector('[data-link-action=preview]').click();true")
        for _ in 0..<100 {
            if workspace.editor.string.contains("[Bookmark](https://example.org/updated)"),
               (try? await view.evaluateJavaScript("document.querySelector('figure.link-chip[data-url=\"https://example.org/updated\"]') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(workspace.editor.string.contains("[Bookmark](https://example.org/updated)"))
        let reopenedAfterPreview = try await view.evaluateJavaScript("document.getElementById('link-popover').classList.contains('open')") as? Bool
        XCTAssertEqual(reopenedAfterPreview, false, "Choosing a bookmark must dismiss the initial Display as menu")
        _ = try await view.evaluateJavaScript("document.querySelector('figure[data-url=\"https://example.org/updated\"] [data-style=embed]').click();true")
        for _ in 0..<100 {
            if workspace.editor.string.contains("[Embed](https://example.org/updated)") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(workspace.editor.string.contains("[Embed](https://example.org/updated)"))
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().first?.text, workspace.editor.string)
    }
    @MainActor func testPlainTextChoiceLeavesCaretAfterURL() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "[URL](https://example.com/path)"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.inline-link') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = try await view.evaluateJavaScript("""
            (()=>{
              const link=document.querySelector('a.inline-link');showLinkMenu(link,true);
              document.querySelector('[data-link-action=plain]').click();
              const selection=getSelection();
              return JSON.stringify({source:source(),collapsed:selection.isCollapsed,
                atEnd:selection.anchorNode?.textContent==='https://example.com/path' && selection.anchorOffset===selection.anchorNode.textContent.length});
            })()
            """) as? String
        XCTAssertEqual(state, "{\"source\":\"https://example.com/path\",\"collapsed\":true,\"atEnd\":true}")
    }
    @MainActor func testMentionChoiceRestoresCaretAfterTheSelectedMention() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let url = "http://127.0.0.1:1/mention-caret"
        try store.save(Note(text: "[Mention](\(url))\n[URL](\(url))"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('a.inline-link').length")) as? Int == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await view.evaluateJavaScript("showLinkMenu(document.querySelectorAll('a.inline-link')[1],true);document.querySelector('[data-link-action=mention]').click();true")
        var caretRestored = false
        for _ in 0..<100 {
            caretRestored = (try? await view.evaluateJavaScript("document.querySelectorAll('a.mention-link').length===2 && getSelection().anchorNode===document.querySelectorAll('a.mention-link')[1].nextSibling && getSelection().anchorOffset===0 && document.activeElement===document.querySelector('.text')")) as? Bool == true
            if caretRestored { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(caretRestored)
        let state = try await view.evaluateJavaScript("""
            (()=>{
              const block=document.querySelector('.text'),link=document.querySelectorAll('a.mention-link')[1];
              const rect=link.getBoundingClientRect();
              block.dispatchEvent(new MouseEvent('mousedown',{button:0,clientX:rect.right+8,clientY:rect.top+rect.height/2,bubbles:true,cancelable:true}));
              const afterClick=getSelection().anchorNode===link.nextSibling && getSelection().anchorOffset===0;
              document.execCommand('insertText',false,' continued');
              return JSON.stringify({afterClick,source:source(),active:document.activeElement===block});
            })()
            """) as? String
        XCTAssertEqual(state, "{\"afterClick\":true,\"source\":\"[Mention](\(url))\\n[Mention](\(url)) continued\",\"active\":true}")
        for _ in 0..<100 {
            if workspace.editor.string.hasSuffix(" continued") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, "[Mention](\(url))\n[Mention](\(url)) continued")
    }
    @MainActor func testInlineDisplayMenuUsesArrowKeysReturnAndEscape() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "[URL](http://127.0.0.1:1/keyboard-link)"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.inline-link') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = try await view.evaluateJavaScript("""
            (()=>{
              const link=document.querySelector('a.inline-link'),menu=document.getElementById('link-popover');
              link.closest('.text').focus();
              const press=key=>document.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
              showLinkMenu(link,true);press('ArrowUp');
              const up=menu.querySelector('button.active')?.dataset.linkAction;
              press('Escape');const dismissed=!menu.classList.contains('open');
              showLinkMenu(link,true);press('ArrowDown');press('ArrowDown');press('ArrowDown');
              const selected=menu.querySelector('button.active')?.dataset.linkAction;
              press('Enter');const selection=getSelection();
              return JSON.stringify({up,dismissed,selected,source:source(),open:menu.classList.contains('open'),
                caretAtEnd:selection.anchorNode?.textContent==='http://127.0.0.1:1/keyboard-link' && selection.anchorOffset===selection.anchorNode.textContent.length});
            })()
            """) as? String
        XCTAssertEqual(state, "{\"up\":\"edit\",\"dismissed\":true,\"selected\":\"plain\",\"source\":\"http://127.0.0.1:1/keyboard-link\",\"open\":false,\"caretAtEnd\":true}")
    }
    @MainActor func testBookmarkDisplayMenuUsesArrowKeysReturnAndEscape() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "[Bookmark](http://127.0.0.1:1/keyboard-bookmark)"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('figure.bookmark') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = try await view.evaluateJavaScript("""
            (()=>{
              const details=document.querySelector('figure.bookmark .link-style');
              const press=key=>document.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
              details.open=true;press('ArrowDown');press('ArrowDown');press('ArrowUp');
              const selected=details.querySelector('button.active')?.dataset.style;
              press('Escape');const dismissed=!details.open;
              details.open=true;press('ArrowDown');press('Enter');
              return JSON.stringify({selected,dismissed,source:source()});
            })()
            """) as? String
        XCTAssertEqual(state, "{\"selected\":\"mention\",\"dismissed\":true,\"source\":\"[Mention](http://127.0.0.1:1/keyboard-bookmark)\"}")
        for _ in 0..<100 {
            if workspace.editor.string == "[Mention](http://127.0.0.1:1/keyboard-bookmark)" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, "[Mention](http://127.0.0.1:1/keyboard-bookmark)")
    }
    @MainActor func testBlockDisplayMenuStaysVisibleAboveFooter() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "[Bookmark](http://127.0.0.1:1/bottom-menu)"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('figure.bookmark .link-style') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try await view.evaluateJavaScript("""
            (()=>{
              const details=document.querySelector('figure.bookmark .link-style');
              const summary=details.querySelector('summary');
              const article=document.querySelector('article');
              article.style.marginTop=Math.max(0,innerHeight-90-summary.getBoundingClientRect().bottom)+'px';
              details.open=true;
              details.dispatchEvent(new Event('toggle'));
              const menu=details.querySelector('.style-options'),rect=menu.getBoundingClientRect();
              const target=document.elementFromPoint(rect.left+20,Math.min(rect.top+20,innerHeight-12));
              return JSON.stringify({visible:rect.top>=8&&rect.bottom<=innerHeight-8,front:menu.contains(target)});
            })()
            """) as? String
        XCTAssertEqual(result, "{\"visible\":true,\"front\":true}")
    }
    @MainActor func testBookmarkChoiceDoesNotReopenPasteMenu() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "Before [URL](https://example.com)"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.inline-link') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await view.evaluateJavaScript("""
            const block=document.querySelector('.text');block.focus();
            const range=document.createRange();range.selectNodeContents(block);range.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(range);
            window.webkit.messageHandlers.note.postMessage({page,kind:'paste',value:'https://example.org/bookmark'});true
            """)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.inline-link[data-url=\"https://example.org/bookmark\"]') !== null && document.getElementById('link-popover').classList.contains('open')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await view.evaluateJavaScript("document.querySelector('[data-link-action=preview]').click();true")
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('figure.link-chip[data-url=\"https://example.org/bookmark\"]') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let menuOpen = try await view.evaluateJavaScript("document.getElementById('link-popover').classList.contains('open') || !!document.querySelector('figure.link-chip .link-style[open]')") as? Bool
        XCTAssertEqual(menuOpen, false)
        XCTAssertTrue(workspace.editor.string.contains("[Bookmark](https://example.org/bookmark)"))
        _ = try await view.evaluateJavaScript("document.querySelector('figure.bookmark[data-url=\"https://example.org/bookmark\"] [data-style=mention]').click();true")
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('a.mention-link[data-url=\"https://example.org/bookmark\"]') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(workspace.editor.string.contains("[Mention](https://example.org/bookmark)"))
        var caretAfterMention = false
        for _ in 0..<100 {
            caretAfterMention = (try? await view.evaluateJavaScript("(()=>{const link=document.querySelector('a.mention-link[data-url=\"https://example.org/bookmark\"]');return !!link && getSelection().anchorNode===link.nextSibling && getSelection().anchorOffset===0;})()")) as? Bool == true
            if caretAfterMention { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(caretAfterMention)
    }
    @MainActor func testCommandASelectsTextAndBookmarkTogether() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "First\n[Preview](http://127.0.0.1:1/select-all)\nLast"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('figure.link-chip') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = try await view.evaluateJavaScript("""
            (()=>{
              document.querySelector('article > .text').focus();
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'a',metaKey:true,bubbles:true,cancelable:true}));
              const text=getSelection().toString();
              const highlighted=document.querySelector('article').classList.contains('whole-note-selected');
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true}));
              return JSON.stringify({first:text.includes('First'),bookmark:text.includes('127.0.0.1'),last:text.includes('Last'),
                highlighted,source:source(),editors:document.querySelectorAll('article > .text').length});
            })()
            """) as? String
        XCTAssertEqual(state, "{\"first\":true,\"bookmark\":true,\"last\":true,\"highlighted\":true,\"source\":\"\",\"editors\":1}")
    }
    @MainActor func testEditMenuSelectAllRoutesToWholeRichNote() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "First\n[Bookmark](http://127.0.0.1:1/menu-select-all)\nLast"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('figure.bookmark') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        workspace.window?.makeFirstResponder(view)
        let menu = NSMenu()
        let delegate = AppDelegate(); delegate.workspace = workspace
        let item = NSMenuItem(title: "Select All", action: #selector(AppDelegate.selectAllContent), keyEquivalent: "a")
        item.target = delegate
        menu.addItem(item)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: workspace.window!.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        var selected = false
        for _ in 0..<100 {
            selected = (try? await view.evaluateJavaScript("wholeNoteSelectionText?.includes('First') && wholeNoteSelectionText?.includes('Last') && wholeNoteSelectionText?.includes('127.0.0.1')")) as? Bool == true
            if selected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(selected)
    }
    @MainActor func testBookmarkAndMentionShowMetadataWithoutChangingSource() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let source = "Before [Mention](https://example.com/page)\n[Bookmark](https://example.com/page)\nAfter"
        try store.save(Note(text: source))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('.mention-link') !== null && document.querySelector('figure.bookmark') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await view.callAsyncJavaScript("resolveLinkMetadata(url,title,description,favicon,image);document.querySelector('.bookmark-preview').dispatchEvent(new Event('load'))", arguments: [
            "url": "https://example.com/page", "title": "Page title", "description": "A useful page description",
            "favicon": "https://example.com/icon.png", "image": "https://example.com/cover.jpg"
        ], in: nil, contentWorld: .page)
        let details = try await view.evaluateJavaScript("""
            JSON.stringify({mention:document.querySelector('.mention-title').textContent,
              mentionDescription:document.querySelector('.mention-tooltip small').textContent,
              bookmark:document.querySelector('.bookmark-title').textContent,
              bookmarkDescription:document.querySelector('.bookmark-description').textContent,
              icons:[...document.querySelectorAll('.link-favicon')].map(e=>e.getAttribute('src')),
              image:document.querySelector('.bookmark-preview').getAttribute('src'),
              imageVisible:!document.querySelector('.bookmark-preview').hidden,
              imageLayout:document.querySelector('figure.bookmark').classList.contains('has-preview-image'),
              bookmarkURL:document.querySelector('.bookmark-host').textContent,
              source:source()})
            """) as? String
        XCTAssertEqual(details, "{\"mention\":\"Page title\",\"mentionDescription\":\"A useful page description\",\"bookmark\":\"Page title\",\"bookmarkDescription\":\"A useful page description\",\"icons\":[\"https://example.com/icon.png\",\"https://example.com/icon.png\"],\"image\":\"https://example.com/cover.jpg\",\"imageVisible\":true,\"imageLayout\":true,\"bookmarkURL\":\"https://example.com/page\",\"source\":\"\(source.replacingOccurrences(of: "\n", with: "\\n"))\"}")
        let fallback = try await view.evaluateJavaScript("document.querySelector('.bookmark-preview').dispatchEvent(new Event('error'));JSON.stringify({imageVisible:!document.querySelector('.bookmark-preview').hidden,imageLayout:document.querySelector('figure.bookmark').classList.contains('has-preview-image'),host:document.querySelector('.bookmark-host').textContent})") as? String
        XCTAssertEqual(fallback, "{\"imageVisible\":false,\"imageLayout\":false,\"host\":\"example.com\"}")
        XCTAssertEqual(workspace.editor.string, source)
    }
    @MainActor func testBackspaceAndDeleteRemoveInlineLinksAtCaret() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "Before [URL](https://example.com/a) middle [URL](https://example.com/b) after"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelectorAll('a.inline-link').length")) as? Int == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pageID = try await view.evaluateJavaScript("page") as? String
        _ = try await view.evaluateJavaScript("""
            const first=document.querySelector('a.inline-link');const firstRange=document.createRange();
            firstRange.setStartAfter(first);firstRange.collapse(true);getSelection().removeAllRanges();getSelection().addRange(firstRange);
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true}));true
            """)
        XCTAssertFalse(workspace.editor.string.contains("example.com/a"))
        _ = try await view.evaluateJavaScript("""
            const second=document.querySelector('a.inline-link');const secondRange=document.createRange();
            secondRange.setStartBefore(second);secondRange.collapse(true);getSelection().removeAllRanges();getSelection().addRange(secondRange);
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Delete',bubbles:true,cancelable:true}));true
            """)
        XCTAssertFalse(workspace.editor.string.contains("example.com/b"))
        XCTAssertTrue(workspace.editor.string.contains("Before"))
        let finalPageID = try await view.evaluateJavaScript("page") as? String
        XCTAssertEqual(finalPageID, pageID)
    }
    @MainActor func testDeletingLastLinkAndTextLeavesOneEmptyEditor() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "First\n[Preview](http://127.0.0.1:1/empty-editor-test)\nLast"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('figure.link-chip') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let afterLinkRemoval = try await view.evaluateJavaScript("""
            (()=>{
              const second=document.querySelectorAll('article > .text')[1];second.focus();
              const range=document.createRange();range.selectNodeContents(second);range.collapse(true);
              getSelection().removeAllRanges();getSelection().addRange(range);
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true}));
              const merged=source();
              for(const block of document.querySelectorAll('article > .text')){
                block.focus();const contents=document.createRange();contents.selectNodeContents(block);
                getSelection().removeAllRanges();getSelection().addRange(contents);
                document.execCommand('delete',false);
              }
              document.querySelector('article > .text').focus();post('input');return merged;
            })()
            """) as? String
        XCTAssertEqual(afterLinkRemoval, "First\nLast")
        let state = try await view.evaluateJavaScript("JSON.stringify({source:source(),editors:document.querySelectorAll('article > .text').length,placeholders:[...document.querySelectorAll('article > .text')].filter(e=>getComputedStyle(e,'::before').content!=='none').length})") as? String
        XCTAssertEqual(state, "{\"source\":\"\",\"editors\":1,\"placeholders\":1}")
        XCTAssertEqual(workspace.editor.string, "")
    }
    @MainActor func testForwardDeleteJoinsTextAroundLink() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "First\n[Preview](http://127.0.0.1:1/forward-delete-test)\nLast"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('figure.link-chip') !== null")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = try await view.evaluateJavaScript("""
            (()=>{
              const first=document.querySelector('article > .text');first.focus();
              const range=document.createRange();range.selectNodeContents(first);range.collapse(false);
              getSelection().removeAllRanges();getSelection().addRange(range);
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'Delete',bubbles:true,cancelable:true}));
              return JSON.stringify({source:source(),editors:document.querySelectorAll('article > .text').length,
                focused:document.activeElement===document.querySelector('article > .text')});
            })()
            """) as? String
        XCTAssertEqual(state, "{\"source\":\"First\\nLast\",\"editors\":1,\"focused\":true}")
        XCTAssertEqual(workspace.editor.string, "First\nLast")
    }
    @MainActor func testLiveSlashMenuSearchAndInsertion() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "[URL](https://example.com)\n"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        let view = workspace.mediaView
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof updateSlashMenu")) as? String == "function" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await view.evaluateJavaScript("const block=document.querySelector('.text');block.focus();const range=document.createRange();range.setStartBefore(block.querySelector('a.inline-link'));range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);document.execCommand('insertText',false,'/h2');true")
        let menuOpen = try await view.evaluateJavaScript("document.getElementById('slash-popover').classList.contains('open')") as? Bool
        let choices = try await view.evaluateJavaScript("[...document.querySelectorAll('#slash-popover button')].map(e=>e.textContent).join(',')") as? String
        let slashDebug = try await view.evaluateJavaScript("JSON.stringify({source:source(),line:currentLine()?.prefix,context:slashContext()?.query,html:document.querySelector('.text').innerHTML})") as? String
        XCTAssertEqual(menuOpen, true, slashDebug ?? "nil")
        XCTAssertEqual(choices, "Heading 2", slashDebug ?? "nil")
        _ = try await view.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));true")
        XCTAssertTrue(workspace.editor.string.hasPrefix("## "))
        let closed = try await view.evaluateJavaScript("document.getElementById('slash-popover').classList.contains('open')") as? Bool
        XCTAssertEqual(closed, false)
    }
    @MainActor func testDropsEnterLiveViewAndCanAddAnotherAttachment() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "skin", withExtension: "mp4", subdirectory: "Fixtures"))
        workspace.editor.insertText("Before After", replacementRange: NSRange(location: 0, length: 0))
        workspace.importMedia([file], range: NSRange(location: 7, length: 0))
        for _ in 0..<100 {
            if workspace.richEditing, ((try? await workspace.mediaView.evaluateJavaScript("document.querySelectorAll('video').length")) as? Int) == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(workspace.richEditing)
        XCTAssertTrue(workspace.editor.string.hasPrefix("Before "))
        XCTAssertTrue(workspace.editor.string.hasSuffix("After"))
        workspace.importMedia([file])
        var renderedCount = 0
        for _ in 0..<100 {
            renderedCount = ((try? await workspace.mediaView.evaluateJavaScript("document.querySelectorAll('video').length")) as? Int) ?? 0
            if renderedCount == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(renderedCount, 2)
        XCTAssertEqual(workspace.notes[workspace.index!].media.count, 2)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try workspace.store.load().first?.text, workspace.editor.string)
    }
    @MainActor func testLiveViewEditsRoundTripAndMediaActuallyLoads() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let file = root.appendingPathComponent("pixel.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!.write(to: file)
        var note = Note(text: "Before\n")
        let video = try XCTUnwrap(Bundle.module.url(forResource: "skin", withExtension: "mp4", subdirectory: "Fixtures"))
        note.attachments = try store.importMedia([file, video], noteID: note.id)
        note.text += "![pixel](\(note.media[0].reference))\n![video](\(note.media[1].reference))\nAfter"
        try store.save(note)
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        XCTAssertTrue(workspace.richEditing)
        let view = workspace.mediaView
        var loaded = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.querySelector('img')?.naturalWidth")) as? Int == 1 { loaded = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(loaded, "Imported image must load through the note-scoped media handler")
        var videoReady = false
        for _ in 0..<100 {
            if ((try? await view.evaluateJavaScript("document.querySelector('video')?.readyState")) as? Int ?? 0) > 0 { videoReady = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(videoReady, "Video player must load media metadata")
        _ = try await view.callAsyncJavaScript("const video=document.querySelector('video');video.muted=true;await video.play();", arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: 200_000_000)
        let playbackTime = try await view.evaluateJavaScript("document.querySelector('video').currentTime") as? Double
        XCTAssertGreaterThan(playbackTime ?? 0, 0)
        _ = try await view.evaluateJavaScript("document.querySelector('video').pause()")
        let renderedSource = try await view.evaluateJavaScript("source()") as? String
        XCTAssertEqual(renderedSource, note.text)
        _ = try await view.evaluateJavaScript("document.querySelector('.text').innerText='Changed';post('input')")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(workspace.editor.string.hasPrefix("Changed"))
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try store.load().first?.text, workspace.editor.string)
        workspace.toggleMarkdownPreview()
        XCTAssertFalse(workspace.richEditing)
        XCTAssertFalse(workspace.scroll.isHidden)
        workspace.toggleMarkdownPreview()
        XCTAssertTrue(workspace.richEditing)
    }
}
