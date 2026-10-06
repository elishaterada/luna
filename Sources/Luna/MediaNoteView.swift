import AppKit
import WebKit
import LunaCore

final class NoteMediaHandler: NSObject, WKURLSchemeHandler {
    var files: [URL: (URL, String)] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let (file, mime) = files[url] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { @MainActor [weak self] in
            let result = await Task.detached { Result { try Data(contentsOf: file, options: .mappedIfSafe) } }.value
            guard !Task.isCancelled, self?.tasks[id] != nil else { return }
            switch result {
            case .success(let data):
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            case .failure(let error): urlSchemeTask.didFailWithError(error)
            }
            self?.tasks[id] = nil
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

private final class WeakNoteMessageHandler: NSObject, WKScriptMessageHandler {
    weak var view: MediaNoteView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        view?.receive(message)
    }
}

final class MediaNoteView: FileDropWebView, WKNavigationDelegate {
    var onChange: ((String) -> Void)?
    var onStructureChange: (() -> Void)?
    private var styleMenuURLOnNextLoad: String?
    private var dismissedStyleURLOnNextLoad: String?
    private var mentionCaretOnNextLoad: (url: String, index: Int)?
    private let mediaHandler: NoteMediaHandler
    private let messageProxy: WeakNoteMessageHandler
    private var lastSource: String?
    private var lastID: UUID?
    private var lastSize: CGFloat = 0
    private var lastDark = false
    private var pageID = UUID().uuidString
    private var metadataTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        mediaHandler = NoteMediaHandler()
        messageProxy = WeakNoteMessageHandler()
        configuration.setURLSchemeHandler(mediaHandler, forURLScheme: "luna-media")
        configuration.userContentController.add(messageProxy, name: "note")
        super.init(frame: .zero, configuration: configuration)
        messageProxy.view = self
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        setAccessibilityLabel("Note with media and live embeds")
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ note: Note, store: RecoveryStore, fontSize: CGFloat, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard lastSource != note.text || lastID != note.id || lastSize != fontSize || lastDark != dark else { return }
        metadataTask?.cancel()
        resolutionTask?.cancel()
        lastSource = note.text; lastID = note.id; lastSize = fontSize; lastDark = dark
        pageID = UUID().uuidString
        mediaHandler.files = Dictionary(uniqueKeysWithValues: note.media.map {
            (Self.mediaURL($0, note: note), (store.attachmentURL($0, noteID: note.id), $0.mediaType))
        })
        loadHTMLString(Self.page(note, fontSize: fontSize, dark: dark, pageID: pageID), baseURL: URL(string: "https://luna.invalid"))
    }
    func suspend() {
        metadataTask?.cancel()
        resolutionTask?.cancel()
        mentionCaretOnNextLoad = nil
        lastSource = nil
        loadHTMLString("", baseURL: nil)
    }
    static func mediaURL(_ attachment: NoteAttachment, note: Note) -> URL {
        URL(string: "luna-media://\(note.id.uuidString.lowercased())/\(attachment.id.uuidString)")!
    }
    func queueStyleMenu(for snippet: String) {
        if let match = InlineLinks.url(in: snippet) {
            styleMenuURLOnNextLoad = match.absoluteString
            return
        }
        for block in NoteEmbeds.blocks(snippet) {
            if case .link(_, let url, _, _) = block {
                styleMenuURLOnNextLoad = url.absoluteString
                return
            }
        }
    }
    func insertSnippet(_ snippet: String, showsStyleMenu: Bool = false) {
        Task {
            _ = try? await callAsyncJavaScript("insertSnippet(snippet, showsStyleMenu)",
                                               arguments: ["snippet": snippet, "showsStyleMenu": showsStyleMenu],
                                               in: nil, contentWorld: .page)
        }
    }
    func selectAllNote() {
        Task { _ = try? await callAsyncJavaScript("selectAllNote()", in: nil, contentWorld: .page) }
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String],
              body["page"] == pageID else { return }
        if body["kind"] == "copySelection", let source = body["source"], source.utf8.count <= 2_000_000 {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
            return
        }
        if body["kind"] == "paste", let value = body["value"] {
            if let snippet = URLPasteChoice.linkedSnippet(for: value) { insertSnippet(snippet, showsStyleMenu: true) }
            else { insertSnippet(value) }
            return
        }
        if let url = body["url"].flatMap(NoteEmbeds.webURL) {
            if body["kind"] == "copyLink" { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string); return }
            if body["kind"] == "openLink" { NSWorkspace.shared.open(url); return }
        }
        guard let source = body["source"], source.utf8.count <= 2_000_000 else { return }
        if body["kind"] == "style", body["display"] == "linked" { dismissedStyleURLOnNextLoad = body["url"] }
        if body["kind"] == "style", body["display"] == "mention",
           let url = body["url"], let index = body["mentionIndex"].flatMap(Int.init) {
            mentionCaretOnNextLoad = (url, index)
        }
        lastSource = ["input", "removeLink", "inlineLink", "slash"].contains(body["kind"]) ? source : nil
        onChange?(source)
        if body["kind"] == "linkPaste" || body["kind"] == "style" { onStructureChange?() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let source = lastSource else { return }
        let currentPage = pageID
        if let mentionCaretOnNextLoad {
            self.mentionCaretOnNextLoad = nil
            Task { _ = try? await callAsyncJavaScript("focusAfterMention(url, index)",
                arguments: ["url": mentionCaretOnNextLoad.url, "index": mentionCaretOnNextLoad.index],
                in: nil, contentWorld: .page) }
        }
        if let styleMenuURLOnNextLoad {
            self.styleMenuURLOnNextLoad = nil
            Task { _ = try? await callAsyncJavaScript("openStyleMenu(url)", arguments: ["url": styleMenuURLOnNextLoad], in: nil, contentWorld: .page) }
        }
        if let dismissedStyleURLOnNextLoad {
            self.dismissedStyleURLOnNextLoad = nil
            Task { _ = try? await callAsyncJavaScript("dismissStyleMenu(url)", arguments: ["url": dismissedStyleURLOnNextLoad], in: nil, contentWorld: .page) }
        }
        let urls = NoteEmbeds.blocks(source).compactMap { block -> URL? in
            if case .embed(_, let url) = block { return url }; return nil
        }
        let bookmarks = NoteEmbeds.blocks(source).compactMap { block -> URL? in
            if case .link(_, let url, _, true) = block { return url }; return nil
        }
        let metadataURLs = Array(Set(bookmarks + InlineLinks.mentionURLs(in: source)))
        metadataTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (URL, LinkMetadata.Details).self) { group in
                for url in metadataURLs {
                    group.addTask { (url, await LinkMetadata.shared.details(for: url)) }
                }
                for await (url, details) in group {
                    guard !Task.isCancelled, let self, self.pageID == currentPage else { group.cancelAll(); return }
                    _ = try? await self.callAsyncJavaScript("resolveLinkMetadata(url, title, description, favicon, image)",
                        arguments: ["url": url.absoluteString, "title": details.title ?? url.host ?? url.absoluteString,
                                    "description": details.description ?? "", "favicon": details.favicon?.absoluteString ?? "",
                                    "image": details.image?.absoluteString ?? ""],
                        in: nil, contentWorld: .page)
                }
            }
        }
        resolutionTask = Task { @MainActor [weak self] in
            for (index, url) in urls.enumerated() {
                let resolved = await EmbedResolver.shared.resolve(url)
                guard !Task.isCancelled, let self, self.pageID == currentPage else { return }
                if resolved != url {
                    _ = try? await self.callAsyncJavaScript("resolveEmbed(index, url)", arguments: ["index": index, "url": resolved.absoluteString],
                                             in: nil, contentWorld: .page)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(["https", "http", "about"].contains(url?.scheme ?? "") ? .allow : .cancel)
        } else if navigationAction.navigationType == .linkActivated {
            if let url, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(url?.scheme == "about" || url?.host == "luna.invalid" ? .allow : .cancel) }
    }

    private static let listScript = #"""
    let formattingList = false;
    function currentLine() {
      const selection=getSelection();
      const node=selection.anchorNode;
      const block=(node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement)?.closest('.text');
      if(!block || !selection.isCollapsed)return null;
      const range=selection.getRangeAt(0).cloneRange();range.selectNodeContents(block);range.setEnd(selection.anchorNode,selection.anchorOffset);
      const before=range.toString();const start=before.lastIndexOf('\n')+1;
      if((before.slice(0,start).match(/^\s*(```|~~~)/gm)||[]).length%2)return null;
      return {block, prefix:before.slice(start), start};
    }
    function replaceBefore(count,text) {
      const selection=getSelection();
      for(let i=0;i<count;i++)selection.modify('extend','backward','character');
      formattingList=true;document.execCommand('insertText',false,text);formattingList=false;
    }
    document.addEventListener('input',()=>{
      if(formattingList)return;
      const line=currentLine();if(!line)return;
      let formatted=line.prefix.replace(/^([ \t]*)(?:[-*+•] )?\[([ xX])\] /,(_,indent,check)=>indent+(check===' '?'☐ ':'☑ '))
        .replace(/^([ \t]*)[-*+] /,'$1• ').replace(/^([ \t]*)(\d+)\) /,'$1$2. ');
      if(formatted!==line.prefix)replaceBefore(line.prefix.length,formatted);
    });
    document.addEventListener('keydown',e=>{
      if(e.key!=='Enter'||e.shiftKey||e.isComposing)return;
      const line=currentLine();if(!line)return;
      const match=line.prefix.match(/^([ \t]*)([•☐☑]|\d+\.) (.*)$/);if(!match)return;
      e.preventDefault();
      if(!match[3].trim())replaceBefore(line.prefix.length,'');
      else {const marker=/^\d/.test(match[2])?(Number.parseInt(match[2])+1)+'.':match[2]==='•'?'•':'☐';document.execCommand('insertText',false,'\n'+match[1]+marker+' ');}
      post('input');
    });
    document.addEventListener('click',e=>{
      if(!e.target.closest('.text'))return;
      const range=document.caretRangeFromPoint(e.clientX,e.clientY);if(!range || range.startContainer.nodeType!==Node.TEXT_NODE)return;
      const node=range.startContainer;const index=range.startOffset;const marker=node.textContent[index];
      if(!['☐','☑'].includes(marker))return;
      range.setEnd(node,index+1);getSelection().removeAllRanges();getSelection().addRange(range);
      document.execCommand('insertText',false,marker==='☐'?'☑':'☐');post('input');
    });
    """#

    private static let editorScript = #"""
    let activeLinkMenu=document.getElementById('link-popover');
    let activeSlashMenu=document.getElementById('slash-popover');
    let activeSlashCommands=[];
    let slashSelection=0;
    let activeLink=null;
    let wholeNoteSelectionText=null;
    function textSource(block) {
      if(!block.querySelector?.('a.inline-link'))return block.innerText.replace(/[\r\u200B]/g,'');
      const clone=block.cloneNode(true);
      clone.querySelectorAll('a.inline-link').forEach(a=>{
        const label=a.classList.contains('mention-link')?'Mention':
          a.textContent===a.dataset.url?'URL':a.textContent.replaceAll('\\','\\\\').replaceAll(']','\\]');
        const url=a.dataset.url.replaceAll('(','%28').replaceAll(')','%29');
        a.replaceWith(document.createTextNode('['+label+']('+url+')'));
      });
      clone.style.cssText='position:absolute;opacity:0;pointer-events:none;left:-10000px;width:72ch;';
      document.body.append(clone);const value=clone.innerText.replace(/[\r\u200B]/g,'');clone.remove();return value;
    }
    function mentionIndexBefore(element,url) {
      return [...document.querySelectorAll('a.mention-link[data-url]')].filter(link=>
        link.dataset.url===url && !!(link.compareDocumentPosition(element)&Node.DOCUMENT_POSITION_FOLLOWING)).length;
    }
    function placeCaretAfterMention(link) {
      const block=link?.closest('.text');if(!block)return;
      block.focus({preventScroll:true});
      const range=document.createRange(),tail=link.nextSibling;
      if(tail?.nodeType===Node.TEXT_NODE)range.setStart(tail,0);
      else range.setStartAfter(link);
      range.collapse(true);getSelection().removeAllRanges();getSelection().addRange(range);
    }
    function focusAfterMention(url,index) {
      const link=[...document.querySelectorAll('a.mention-link[data-url]')].filter(link=>link.dataset.url===url)[index];
      if(link)placeCaretAfterMention(link);
    }
    function mergeAdjacentText(block, backwards) {
      const left=backwards?block.previousElementSibling:block;
      const right=backwards?block:block.nextElementSibling;
      if(!left?.matches('.text')||!right?.matches('.text'))return;
      const leftEmpty=left.textContent.length===0,rightEmpty=right.textContent.length===0;
      if(leftEmpty)left.replaceChildren();
      if(rightEmpty)right.replaceChildren();
      const separator=leftEmpty&&rightEmpty?null:document.createTextNode('\n');
      if(separator)left.append(separator);
      while(right.firstChild)left.append(right.firstChild);
      right.remove();left.focus({preventScroll:true});
      const caret=document.createRange();
      if(separator)caret.setStart(separator,backwards?separator.length:0);
      else {caret.selectNodeContents(left);caret.collapse(false);}
      caret.collapse(true);getSelection().removeAllRanges();getSelection().addRange(caret);
    }
    function positionPopover(popover,rect) {
      popover.classList.add('open');
      if(popover===activeLinkMenu){
        const gap=6,margin=8,compact=popover.classList.contains('style-choices');
        const available=Math.max(0,innerWidth-rect.right-gap-margin);
        const minimum=compact?96:160,preferred=compact?190:240;
        const width=Math.max(minimum,Math.min(preferred,available));
        popover.style.width=width+'px';
        popover.classList.toggle('tight',width<140);
        const height=popover.offsetHeight;
        const fitsBeside=available>=minimum;
        popover.style.left=(fitsBeside?rect.right+gap:Math.max(margin,innerWidth-width-margin))+'px';
        const top=fitsBeside?rect.top-6:rect.bottom+6;
        popover.style.top=Math.max(margin,Math.min(top,innerHeight-height-margin))+'px';
        return;
      }
      const width=popover.offsetWidth,height=popover.offsetHeight;
      popover.style.left=Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';
      popover.style.top=(rect.bottom+height+8<innerHeight?rect.bottom+6:Math.max(8,rect.top-height-6))+'px';
    }
    function clearKeyboardChoice(menu){
      delete menu.dataset.keyboardIndex;
      menu.classList.remove('keyboard-nav');
      menu.querySelectorAll('button.active').forEach(button=>button.classList.remove('active'));
    }
    function positionBlockStyleMenu(details){
      const summary=details.querySelector('summary'),menu=details.querySelector('.style-options');
      if(!summary||!menu)return;
      const anchor=summary.getBoundingClientRect(),height=menu.offsetHeight,width=menu.offsetWidth,margin=8,gap=6;
      const below=anchor.bottom+gap;
      const top=below+height<=innerHeight-margin?below:anchor.top-height-gap;
      menu.style.top=Math.max(margin,Math.min(top,innerHeight-height-margin))+'px';
      menu.style.left=Math.max(margin,Math.min(anchor.left,innerWidth-width-margin))+'px';
    }
    function hideLinkMenu(){activeLinkMenu.classList.remove('open');clearKeyboardChoice(activeLinkMenu);activeLink=null;}
    function validLink(value) {try{const url=new URL(value);return ['http:','https:'].includes(url.protocol)&&!!url.host&&!url.username&&!url.password?url.href:null;}catch{return null;}}
    function showLinkMenu(link,styles=false) {
      if(!link?.isConnected)return;
      activeLink=link;activeSlashMenu.classList.remove('open');
      activeLinkMenu.classList.toggle('style-choices',styles);
      activeLinkMenu.innerHTML=styles?'<div class="hint">Display as</div><button data-link-action="mention">Mention</button><button data-link-action="linked">Linked Text</button><button data-link-action="plain">Plain Text</button><button data-link-action="preview">Bookmark</button><button data-link-action="embed">Embed Site</button><div class="divider"></div><button data-link-action="edit">Edit link</button>':'<div class="hint">'+link.dataset.url.replaceAll('&','&amp;').replaceAll('<','&lt;')+'</div><button data-link-action="open">Open link</button><button data-link-action="copy">Copy link</button><button data-link-action="edit">Edit link</button><div class="divider"></div><button data-link-action="styles">Display as…</button><button data-link-action="remove">Remove link</button>';
      delete activeLinkMenu.dataset.keyboardIndex;
      const rectangles=link.getClientRects();positionPopover(activeLinkMenu,rectangles[rectangles.length-1]??link.getBoundingClientRect());
    }
    activeLinkMenu.addEventListener('click',e=>{
      const action=e.target.closest('[data-link-action]')?.dataset.linkAction;
      if(!action||!activeLink)return;
      const link=activeLink,url=link.dataset.url;
      const escapedURL=url.replaceAll('(','%28').replaceAll(')','%29');
      if(action==='styles'){showLinkMenu(link,true);return;}
      if(action==='edit'){
        activeLinkMenu.classList.remove('style-choices');
        activeLinkMenu.innerHTML='<div class="hint">Edit link</div><input data-link-field="title" aria-label="Link title"><input data-link-field="url" aria-label="Link URL"><button data-link-action="save">Save link</button><button data-link-action="remove">Remove link</button>';
        activeLinkMenu.querySelector('[data-link-field=title]').value=link.querySelector('.mention-title')?.textContent??link.textContent;
        activeLinkMenu.querySelector('[data-link-field=url]').value=url;
        const rectangles=link.getClientRects();positionPopover(activeLinkMenu,rectangles[rectangles.length-1]??link.getBoundingClientRect());activeLinkMenu.querySelector('input').focus();return;
      }
      if(action==='save'){
        const title=activeLinkMenu.querySelector('[data-link-field=title]').value.trim();
        const next=validLink(activeLinkMenu.querySelector('[data-link-field=url]').value.trim());
        if(!title||title.includes('\n')||!next){activeLinkMenu.querySelector('[data-link-field=url]').setCustomValidity('Enter a web URL and a one-line title.');activeLinkMenu.querySelector('[data-link-field=url]').reportValidity();return;}
        link.dataset.url=next;link.href=next;link.classList.remove('mention-link');link.textContent=title;post('inlineLink');hideLinkMenu();return;
      }
      if(action==='copy'||action==='open'){window.webkit.messageHandlers.note.postMessage({page,kind:action==='copy'?'copyLink':'openLink',url});hideLinkMenu();return;}
      if(action==='remove'){link.replaceWith(document.createTextNode(link.querySelector('.mention-title')?.textContent??link.textContent));post('inlineLink');hideLinkMenu();return;}
      if(action==='linked'){
        if(link.classList.contains('mention-link')){link.replaceWith(document.createTextNode('[URL]('+escapedURL+')'));hideLinkMenu();post('style',{url,display:action});}
        else hideLinkMenu();
        return;
      }
      if(action==='mention'){
        if(link.classList.contains('mention-link')){hideLinkMenu();placeCaretAfterMention(link);return;}
        const mentionIndex=mentionIndexBefore(link,url);
        link.replaceWith(document.createTextNode('[Mention]('+escapedURL+')'));hideLinkMenu();post('style',{url,display:action,mentionIndex:String(mentionIndex)});return;
      }
      if(action==='plain'){
        const block=link.closest('.text'),text=document.createTextNode(url);link.replaceWith(text);
        block.focus({preventScroll:true});const caret=document.createRange();caret.setStart(text,text.length);caret.collapse(true);
        getSelection().removeAllRanges();getSelection().addRange(caret);
        post('inlineLink');hideLinkMenu();return;
      }
      const marker=action==='preview'?'[Bookmark]('+escapedURL+')':'[Embed]('+escapedURL+')';
      link.replaceWith(document.createTextNode('\n'+marker+'\n'));hideLinkMenu();post('style',{url,display:action});
    });
    activeLinkMenu.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target.matches('input')){e.preventDefault();activeLinkMenu.querySelector('[data-link-action=save]').click();}});
    document.addEventListener('toggle',e=>{
      if(!e.target.matches?.('.link-style'))return;
      if(e.target.open)positionBlockStyleMenu(e.target);
      else clearKeyboardChoice(e.target);
    },true);
    document.addEventListener('pointermove',e=>{
      const menu=e.target instanceof Element?e.target.closest('#link-popover,.link-style'):null;
      if(menu?.classList.contains('keyboard-nav'))clearKeyboardChoice(menu);
    },true);
    document.addEventListener('keydown',e=>{
      if(e.isComposing||e.altKey||e.metaKey||e.ctrlKey||e.shiftKey)return;
      const menu=activeLinkMenu.classList.contains('open')?activeLinkMenu:
        [...document.querySelectorAll('.link-style[open]')].at(-1);
      if(!menu)return;
      if(e.key==='Escape'){
        e.preventDefault();e.stopPropagation();
        if(menu===activeLinkMenu)hideLinkMenu();else{menu.open=false;clearKeyboardChoice(menu);}
        return;
      }
      if(e.target instanceof Element&&e.target.closest('input,textarea'))return;
      if(e.key!=='ArrowDown'&&e.key!=='ArrowUp'&&e.key!=='Enter')return;
      const buttons=[...menu.querySelectorAll('button[data-link-action],button[data-style]')];
      if(!buttons.length)return;
      const current=menu.dataset.keyboardIndex===undefined?-1:Number(menu.dataset.keyboardIndex);
      const next=e.key==='ArrowDown'?(current+1)%buttons.length:
        e.key==='ArrowUp'?(current<0?buttons.length-1:(current-1+buttons.length)%buttons.length):
        (current<0?0:current);
      e.preventDefault();e.stopPropagation();
      if(e.key==='Enter'){buttons[next].click();return;}
      menu.dataset.keyboardIndex=String(next);
      menu.classList.add('keyboard-nav');
      buttons.forEach((button,index)=>button.classList.toggle('active',index===next));
    },true);
    document.addEventListener('click',e=>{
      const link=e.target.closest('a.inline-link');
      if(link){e.preventDefault();showLinkMenu(link);return;}
      if(!e.composedPath().includes(activeLinkMenu))hideLinkMenu();
      if(!e.composedPath().includes(activeSlashMenu))activeSlashMenu.classList.remove('open');
    });
    function selectAllNote(){
      hideLinkMenu();activeSlashMenu.classList.remove('open');
      const article=document.querySelector('article'),range=document.createRange();range.selectNodeContents(article);
      getSelection().removeAllRanges();getSelection().addRange(range);
      wholeNoteSelectionText=getSelection().toString();
      article.classList.add('whole-note-selected');
    }
    document.addEventListener('keydown',e=>{
      if(!e.metaKey||e.altKey||e.ctrlKey||e.shiftKey||e.key.toLowerCase()!=='a'||
         !document.activeElement?.closest('article'))return;
      e.preventDefault();selectAllNote();
    });
    document.addEventListener('selectionchange',()=>{
      if(wholeNoteSelectionText!==null&&getSelection().toString()!==wholeNoteSelectionText){
        wholeNoteSelectionText=null;document.querySelector('article').classList.remove('whole-note-selected');
      }
    });
    document.addEventListener('pointerdown',e=>{if(e.target.closest('article')){
      wholeNoteSelectionText=null;document.querySelector('article').classList.remove('whole-note-selected');
    }},true);
    document.addEventListener('copy',e=>{
      if(wholeNoteSelectionText===null||getSelection().toString()!==wholeNoteSelectionText)return;
      e.clipboardData.setData('text/plain',source());e.preventDefault();
    });
    document.addEventListener('keydown',e=>{
      if(!e.metaKey||e.altKey||e.ctrlKey||e.shiftKey||e.key.toLowerCase()!=='c'||
         wholeNoteSelectionText===null||getSelection().toString()!==wholeNoteSelectionText)return;
      e.preventDefault();window.webkit.messageHandlers.note.postMessage({page,kind:'copySelection',source:source()});
    });
    document.addEventListener('keydown',e=>{
      if(e.key!=='Backspace'&&e.key!=='Delete'&&e.key!=='Del')return;
      const article=document.querySelector('article'),selection=getSelection();
      if(!wholeNoteSelectionText||selection.isCollapsed||selection.toString()!==wholeNoteSelectionText)return;
      wholeNoteSelectionText=null;article.classList.remove('whole-note-selected');
      e.preventDefault();hideLinkMenu();activeSlashMenu.classList.remove('open');
      const block=document.createElement('div');block.className='text';block.contentEditable='true';
      block.spellcheck=false;block.dataset.block='';article.replaceChildren(block);block.focus({preventScroll:true});
      post('structure');
    });
    const slashCommands=[
      {group:'Basic blocks',name:'Text',keys:['text','paragraph'],insert:''},
      {group:'Basic blocks',name:'Heading 1',keys:['h1','heading'],insert:'# '},
      {group:'Basic blocks',name:'Heading 2',keys:['h2','heading'],insert:'## '},
      {group:'Basic blocks',name:'Quote',keys:['quote'],insert:'> '},
      {group:'Lists',name:'Bulleted list',keys:['bullet','list'],insert:'• '},
      {group:'Lists',name:'Numbered list',keys:['number','list'],insert:'1. '},
      {group:'Lists',name:'To-do list',keys:['todo','check','list'],insert:'☐ '},
      {group:'More',name:'Code block',keys:['code'],insert:'```\n\n```'},
      {group:'More',name:'Divider',keys:['divider','rule'],insert:'---'}
    ];
    function slashContext(){
      const line=currentLine();if(!line)return null;
      const match=line.prefix.match(/^([ \t]*)\/([^\n]*)$/);if(!match)return null;
      return {...line,query:match[2].toLowerCase(),length:match[0].length};
    }
    function updateSlashMenu(){
      const context=slashContext();
      if(!context){activeSlashMenu.classList.remove('open');return;}
      activeSlashCommands=slashCommands.filter(c=>(c.name+' '+c.keys.join(' ')).toLowerCase().includes(context.query));
      slashSelection=0;let group='';activeSlashMenu.replaceChildren();
      activeSlashCommands.forEach((command,index)=>{
        if(command.group!==group){group=command.group;const hint=document.createElement('div');hint.className='hint';hint.textContent=group;activeSlashMenu.append(hint);}
        const button=document.createElement('button');button.type='button';button.dataset.slashIndex=index;button.setAttribute('role','option');button.textContent=command.name;activeSlashMenu.append(button);
      });
      if(!activeSlashCommands.length){activeSlashMenu.classList.remove('open');return;}
      activeSlashMenu.querySelector('button')?.classList.add('active');
      const rect=getSelection().getRangeAt(0).getBoundingClientRect();positionPopover(activeSlashMenu,rect);
    }
    function applySlash(index){
      const command=activeSlashCommands[index],context=slashContext();if(!command||!context)return;
      replaceBefore(context.length,command.insert);
      activeSlashMenu.classList.remove('open');post('slash');
    }
    activeSlashMenu.addEventListener('mousedown',e=>e.preventDefault());
    activeSlashMenu.addEventListener('click',e=>{const index=e.target.closest('[data-slash-index]')?.dataset.slashIndex;if(index!==undefined)applySlash(Number(index));});
    document.addEventListener('keydown',e=>{
      if(e.key==='Escape'){hideLinkMenu();activeSlashMenu.classList.remove('open');return;}
      if(!activeSlashMenu.classList.contains('open'))return;
      if(e.key==='ArrowDown'||e.key==='ArrowUp'){
        e.preventDefault();slashSelection=(slashSelection+(e.key==='ArrowDown'?1:-1)+activeSlashCommands.length)%activeSlashCommands.length;
        activeSlashMenu.querySelectorAll('[data-slash-index]').forEach((b,i)=>b.classList.toggle('active',i===slashSelection));return;
      }
      if(e.key==='Enter'){e.preventDefault();applySlash(slashSelection);}
    });
    """#

    static func page(_ note: Note, fontSize: CGFloat, dark: Bool, pageID: String) -> String {
        let escape = NoteEmbeds.escape
        var html = ""
        var embedIndex = 0
        var previewIndex = 0
        let blocks = NoteEmbeds.blocks(note.text)
        func styleMenu() -> String {
            """
            <details class="link-style"><summary aria-label="Change link display">Display as</summary><div class="style-options" role="group" aria-label="Link display style"><button type="button" data-style="mention">Mention</button><button type="button" data-style="linked">Linked Text</button><button type="button" data-style="plain">Plain Text</button><button type="button" data-style="preview">Bookmark</button><button type="button" data-style="embed">Embed Site</button></div></details>
            """
        }
        func textBlock(_ text: String, spacer: Bool = false) -> String {
            "<div class=\"text\" contenteditable=\"true\" spellcheck=\"false\" data-block data-spacer=\"\(spacer)\">\(InlineLinks.html(text))</div>"
        }
        for (index, block) in blocks.enumerated() {
            if index == 0, case .text = block { } else if index == 0 { html += textBlock("", spacer: true) }
            switch block {
            case .text(let text): html += textBlock(text)
            case .media(let source, let id):
                let content: String
                if let item = note.media.first(where: { $0.id == id }) {
                    let url = escape(mediaURL(item, note: note).absoluteString)
                    let label = escape(item.filename)
                    if item.mediaType.hasPrefix("image/") { content = "<img src=\"\(url)\" alt=\"\(label)\">" }
                    else if item.mediaType.hasPrefix("audio/") { content = "<audio controls preload=\"metadata\" src=\"\(url)\"></audio>" }
                    else { content = "<video controls playsinline preload=\"metadata\" src=\"\(url)\"></video>" }
                    html += "<figure data-block data-source=\"\(escape(source))\">\(content)<figcaption>\(label)</figcaption><button class=\"remove\" aria-label=\"Remove attachment\"></button></figure>"
                } else {
                    html += "<figure data-block data-source=\"\(escape(source))\">Attachment unavailable<button class=\"remove\" aria-label=\"Remove attachment\"></button></figure>"
                }
            case .link(let source, let url, let label, let preview):
                let title = preview ? (url.host ?? "Website") : (label == "URL" ? url.absoluteString : label)
                let previewAttribute = preview ? " data-preview=\"\(previewIndex)\"" : ""
                if preview { previewIndex += 1 }
                let linkContent = preview ? """
                    <a class="bookmark-content" href="\(escape(url.absoluteString))" target="_blank"><img class="bookmark-preview" alt="" hidden><img class="link-favicon" alt="" hidden><span class="bookmark-copy"><strong class="bookmark-title"\(previewAttribute)>\(escape(title))</strong><span class="bookmark-description">\(escape(url.absoluteString))</span><small class="bookmark-host">\(escape(url.host ?? "Website"))</small></span></a>
                    """ : "<a href=\"\(escape(url.absoluteString))\" target=\"_blank\">\(escape(title))</a>"
                html += "<figure class=\"\(preview ? "link-chip bookmark" : "linked-text")\" data-block data-source=\"\(escape(source))\" data-url=\"\(escape(url.absoluteString))\">\(linkContent)\(styleMenu())<button class=\"remove\" aria-label=\"Remove link\"></button></figure>"
            case .embed(let source, let url):
                let value = escape(url.absoluteString)
                html += """
                <figure data-block data-source="\(escape(source))" data-url="\(value)"><iframe data-embed="\(embedIndex)" src="\(value)" title="\(escape(url.host ?? "Embedded content"))" sandbox="allow-scripts allow-same-origin allow-presentation" allow="fullscreen; autoplay; encrypted-media; picture-in-picture" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe><figcaption><a href="\(value)" target="_blank">\(escape(url.host ?? "Open original")) ↗</a><span> · Open the original if this site cannot be embedded</span></figcaption>\(styleMenu())<button class="remove" aria-label="Remove embed"></button></figure>
                """
                embedIndex += 1
            }
            if index == blocks.count - 1 { if case .text = block { } else { html += textBlock("", spacer: true) } }
            else if case .text = block { } else if case .text = blocks[index + 1] { } else { html += textBlock("", spacer: true) }
        }
        if blocks.isEmpty { html = textBlock("") }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(pageID)'; style-src 'unsafe-inline'; img-src luna-media: https:; media-src luna-media: https:; frame-src https: http:; base-uri 'none'; form-action 'none'">
        <style>
        :root {color-scheme: \(dark ? "dark" : "light");}
        body {box-sizing:border-box;min-height:100vh;margin:0;padding:24px 40px 80px;color:\(dark ? "#cccccc" : "#242833");font:\(fontSize)px/1.8 -apple-system,BlinkMacSystemFont,sans-serif;}
        article {max-width:72ch;margin:0;} .text {white-space:pre-wrap;overflow-wrap:anywhere;min-height:1.8em;outline:none;}
        .inline-link {text-decoration:underline;text-underline-offset:3px;cursor:pointer;} .inline-link:hover {text-decoration-thickness:2px;}
        .inline-link:not(.mention-link),figure.linked-text > a {color:\(dark ? "#a0a4aa" : "#606773");}
        .mention-link {display:inline-flex;align-items:center;gap:5px;max-width:100%;vertical-align:baseline;text-decoration:none;font-weight:600;position:relative;}
        .mention-title {overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:42ch;}
        .mention-tooltip {display:none;position:absolute;z-index:12;left:0;top:calc(100% + 6px);width:min(320px,calc(100vw - 80px));box-sizing:border-box;padding:10px 12px;border:1px solid #8885;border-radius:9px;background:\(dark ? "#292929" : "#f7f7f7");box-shadow:0 10px 26px #0005;text-align:left;white-space:normal;font-size:12px;font-weight:400;user-select:none;}
        .mention-tooltip strong,.mention-tooltip small {display:block;overflow-wrap:anywhere;} .mention-tooltip small {opacity:.72;margin-top:4px;} .mention-link:hover .mention-tooltip,.mention-link:focus-visible .mention-tooltip {display:block;}
        .text:empty:before {content:'Write something…';color:\(dark ? "#777d85" : "#858b92");pointer-events:none;}
        .text:empty:not(:focus):not(:last-child):before {content:none;}
        .link-chip {border:1px solid #8884;border-radius:10px;padding:12px 16px;} .link-chip small {display:block;font-size:12px;opacity:.65;overflow-wrap:anywhere;}
        .bookmark-content {display:flex;align-items:flex-start;gap:12px;padding-right:24px;text-decoration:none;}
        .bookmark-copy {display:flex;flex-direction:column;gap:3px;min-width:0;flex:1;} .bookmark-title {line-height:1.35;overflow-wrap:anywhere;}
        .bookmark-description {font-size:13px;line-height:1.4;opacity:.8;overflow:hidden;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow-wrap:anywhere;}
        .bookmark-host {line-height:1.3;} .link-favicon {width:24px;height:24px;object-fit:contain;border-radius:5px;flex:none;} .link-favicon[hidden] {display:none!important;}
        .bookmark-preview[hidden] {display:none!important;}
        .bookmark.has-preview-image {padding:0;overflow:hidden;}
        .bookmark.has-preview-image .bookmark-content {display:grid;grid-template-columns:minmax(130px,28%) minmax(0,1fr);grid-template-rows:40px 130px;gap:0;height:170px;padding:0;align-items:stretch;}
        .bookmark.has-preview-image .bookmark-preview {grid-column:1;grid-row:1 / span 2;width:100%;height:170px;max-height:none;object-fit:cover;border-radius:0;}
        .bookmark.has-preview-image .link-favicon {grid-column:2;grid-row:1;width:22px;height:22px;margin:16px 16px 0;}
        .bookmark.has-preview-image .bookmark-copy {grid-column:2;grid-row:2;padding:8px 16px 16px;gap:5px;}
        .bookmark.has-preview-image .bookmark-title {overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
        .bookmark.has-preview-image .bookmark-host {margin-top:auto;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;overflow-wrap:normal;}
        .mention-link .link-favicon {width:16px;height:16px;border-radius:3px;}
        figure {position:relative;margin:20px 0;padding:0;} figure.linked-text {margin:0;overflow-wrap:anywhere;} img,video {display:block;max-width:100%;max-height:580px;border-radius:8px;}
        .link-style {display:inline-block;position:relative;width:0;margin-left:0;vertical-align:middle;font-size:12px;line-height:1.5;white-space:nowrap;opacity:0;visibility:hidden;pointer-events:none;user-select:none;}
        figure:hover .link-style,.link-style:focus-within,.link-style[open] {width:auto;margin-left:12px;opacity:1;visibility:visible;pointer-events:auto;}
        figure.style-dismissed .link-style:not([open]) {width:0;margin-left:0;opacity:0;visibility:hidden;pointer-events:none;}
        .bookmark.has-preview-image .link-style {position:absolute;right:42px;top:10px;margin-left:0;}
        .link-style summary {cursor:pointer;color:inherit;opacity:.65;list-style:none;border-radius:6px;padding:2px 5px;}
        .link-style summary::-webkit-details-marker {display:none;} .link-style summary:hover,.link-style summary:focus-visible {opacity:1;background:#8883;}
        .style-options {position:fixed;left:0;top:0;z-index:1000;min-width:164px;max-height:calc(100vh - 16px);overflow-y:auto;box-sizing:border-box;padding:5px;background:\(dark ? "#292929" : "#f7f7f7");border:1px solid #8885;border-radius:10px;box-shadow:0 10px 26px #0005;}
        .style-options button {display:block;width:100%;padding:7px 10px;text-align:left;color:inherit;background:none;border:0;border-radius:6px;font:inherit;cursor:pointer;}
        .style-options button:hover,.style-options button:focus-visible,.style-options button.active {background:#8884;}
        .link-style.keyboard-nav .style-options button:hover:not(.active) {background:none;}
        .editor-popover {display:none;box-sizing:border-box;position:fixed;z-index:20;min-width:230px;max-width:min(340px,calc(100vw - 24px));padding:7px;background:\(dark ? "#292929" : "#f7f7f7");border:1px solid #8885;border-radius:10px;box-shadow:0 10px 26px #0005;font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;}
        #link-popover {min-width:0;max-width:none;} #link-popover.tight {padding:4px;font-size:11px;} #link-popover.tight button {padding:6px 5px;} #link-popover.tight .hint {font-size:10px;padding:4px 5px;}
        .editor-popover.open {display:block;} .editor-popover button {display:block;width:100%;padding:7px 9px;text-align:left;color:inherit;background:none;border:0;border-radius:6px;font:inherit;cursor:pointer;}
        .editor-popover button:hover,.editor-popover button:focus-visible,.editor-popover button.active {background:#8884;outline:none;}
        #link-popover.keyboard-nav button:hover:not(.active) {background:none;}
        .editor-popover input {box-sizing:border-box;width:100%;margin:4px 0;padding:7px 9px;background:transparent;color:inherit;border:1px solid #8887;border-radius:6px;font:inherit;}
        .editor-popover .hint {font-size:11px;opacity:.7;padding:5px 9px;} .editor-popover .divider {height:1px;margin:5px 2px;background:#8884;}
        audio {width:100%;} iframe {display:block;width:100%;height:380px;border:1px solid #8883;border-radius:8px;background:#fff;}
        figcaption {font-size:11px;opacity:.7;margin-top:6px;overflow-wrap:anywhere;} a {color:inherit;} .remove {position:absolute;right:8px;top:8px;border:0;border-radius:50%;width:26px;height:26px;background:#222c;color:white;padding:0;box-sizing:border-box;appearance:none;cursor:pointer;opacity:0;}
        .remove::before,.remove::after {content:'';position:absolute;left:50%;top:50%;width:13px;height:2px;background:currentColor;border-radius:1px;pointer-events:none;transform:translate(-50%,-50%) rotate(45deg);}
        .remove::after {transform:translate(-50%,-50%) rotate(-45deg);}
        figure:hover .remove, .remove:focus-visible {opacity:1;} ::selection {background:#19f9d838;}
        article.whole-note-selected > * {background-color:#19f9d838;}
        </style></head><body><article>\(html)</article><div id="link-popover" class="editor-popover" role="dialog" aria-label="Link options"></div><div id="slash-popover" class="editor-popover" role="listbox" aria-label="Insert block"></div>
        <script nonce="\(pageID)">
        const page = '\(pageID)';
        function source() {return [...document.querySelectorAll('[data-block]')].filter(e=>e.dataset.spacer!=='true'||e.innerText!=='').map(e=>e.dataset.source ?? textSource(e)).join('\\n');}
        function post(kind, extra={}) {window.webkit.messageHandlers.note.postMessage({page,kind,source:source(),...extra});}
        \(listScript)
        \(editorScript)
        document.addEventListener('input',e=>{const block=e.target.closest('.text');if(block){if(e.inputType?.startsWith('delete')&&block.textContent==='')block.replaceChildren();post('input');updateSlashMenu();}});
        document.addEventListener('click',e=>{
          document.querySelectorAll('.link-style[open]').forEach(menu=>{
            if(menu.contains(e.target))return;
            menu.open=false;
            const figure=menu.closest('figure');if(figure?.matches(':hover'))figure.classList.add('style-dismissed');
          });
          if(e.target.matches('.remove')){e.target.closest('figure').remove();post('structure');return;}
          const style=e.target.closest('[data-style]');if(!style)return;
          const figure=style.closest('figure[data-url]');if(!figure)return;
          const unchanged=(style.dataset.style==='linked'&&figure.classList.contains('linked-text')) ||
            (style.dataset.style==='preview'&&figure.classList.contains('link-chip')) ||
            (style.dataset.style==='embed'&&figure.querySelector('iframe'));
          if(unchanged){style.closest('.link-style').open=false;figure.classList.add('style-dismissed');style.blur();return;}
          const url=figure.dataset.url;const escaped=url.replaceAll('(','%28').replaceAll(')','%29');
          const mentionIndex=style.dataset.style==='mention'?mentionIndexBefore(figure,url):0;
          figure.dataset.source=style.dataset.style==='plain'?url:style.dataset.style==='linked'?'[URL]('+escaped+')':
            style.dataset.style==='mention'?'[Mention]('+escaped+')':style.dataset.style==='preview'?'[Bookmark]('+escaped+')':'[Embed]('+escaped+')';
          post('style',{url,display:style.dataset.style,mentionIndex:String(mentionIndex)});
        });
        document.addEventListener('pointerleave',e=>{if(e.target.matches('figure.style-dismissed'))e.target.classList.remove('style-dismissed');},true);
        document.addEventListener('focusin',e=>{e.target.closest('.link-style')?.closest('figure')?.classList.remove('style-dismissed');});
        document.addEventListener('keydown',e=>{
          if(e.defaultPrevented||e.isComposing||e.altKey||e.metaKey||e.ctrlKey||e.shiftKey)return;
          const backwards=e.key==='Backspace',forwards=e.key==='Delete'||e.key==='Del';
          if(!backwards&&!forwards)return;
          const selection=getSelection();if(!selection?.isCollapsed||!selection.rangeCount)return;
          const node=selection.anchorNode;
          const block=(node.nodeType===Node.ELEMENT_NODE?node:node.parentElement)?.closest('.text');
          if(!block)return;
          const range=selection.getRangeAt(0),edge=range.cloneRange();edge.selectNodeContents(block);
          const sibling=node.nodeType===Node.TEXT_NODE?
            (backwards&&range.startOffset===0?node.previousSibling:forwards&&range.startOffset===node.textContent.length?node.nextSibling:null):
            (backwards?node.childNodes[range.startOffset-1]:node.childNodes[range.startOffset]);
          if(sibling?.matches?.('a.inline-link')){e.preventDefault();sibling.remove();post('inlineLink');return;}
          if(backwards)edge.setEnd(range.startContainer,range.startOffset);
          else edge.setStart(range.startContainer,range.startOffset);
          if(edge.toString().length)return;
          const adjacent=backwards?block.previousElementSibling:block.nextElementSibling;
          if(!adjacent?.matches('figure[data-url]'))return;
          e.preventDefault();adjacent.remove();mergeAdjacentText(block,backwards);post('removeLink');
        });
        document.addEventListener('mousedown',event=>{
          if(event.button===0 && event.target.matches('.text')){
            const block=event.target,link=block.lastElementChild;
            const rect=link?.getBoundingClientRect();
            if(link?.matches('a.mention-link') && link.nextSibling?.textContent==='\\u200B' &&
               event.clientX>=rect.right && event.clientY>=rect.top-4 && event.clientY<=rect.bottom+4){
              event.preventDefault();placeCaretAfterMention(link);return;
            }
          }
          if(event.button!==0 || !event.target.matches('html,body,article'))return;
          const article=document.querySelector('article');
          let last=article.lastElementChild;
          if(last && event.clientY<last.getBoundingClientRect().bottom)return;
          event.preventDefault();
          if(!last?.matches('.text')){
            last=document.createElement('div');last.className='text';last.contentEditable='true';
            last.dataset.block='';last.dataset.spacer='true';article.append(last);
          }
          last.focus({preventScroll:true});
          const range=document.createRange();range.selectNodeContents(last);range.collapse(false);
          const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
        });
        function placeCaret(x,y) {const r=document.caretRangeFromPoint(x,y);if(r&&r.startContainer.parentElement.closest('.text')){const s=getSelection();s.removeAllRanges();s.addRange(r);}}
        function insertSnippet(snippet, showsStyleMenu=false) {
          const selected=getSelection();const node=selected.anchorNode;let block=(node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement)?.closest('.text');
          if(!block){block=document.querySelector('.text:last-child');if(!block){block=document.createElement('div');block.className='text';block.contentEditable='true';block.dataset.block='';document.querySelector('article').append(block);}block.focus();const range=document.createRange();range.selectNodeContents(block);range.collapse(false);selected.removeAllRanges();selected.addRange(range);}
          if(showsStyleMenu){const match=snippet.match(/^\\[URL\\]\\((https?:\\/\\/[^)]+)\\)$/);if(match){const range=selected.getRangeAt(0);range.deleteContents();const a=document.createElement('a');a.className='inline-link';a.dataset.url=match[1];a.href=match[1];a.textContent=match[1];range.insertNode(a);range.setStartAfter(a);range.collapse(true);selected.removeAllRanges();selected.addRange(range);post('inlineLink');showLinkMenu(a,true);return;}}
          document.execCommand('insertText',false,snippet);post('structure');
        }
        document.addEventListener('paste',e=>{if(!e.target.closest('.text'))return;const text=e.clipboardData.getData('text/plain');e.preventDefault();if(/^(https?:\\/\\/\\S+)$/.test(text.trim())||/<iframe/i.test(text)){window.webkit.messageHandlers.note.postMessage({page,kind:'paste',value:text});}else{document.execCommand('insertText',false,text);post('input');}});
        document.addEventListener('scroll',()=>{hideLinkMenu();activeSlashMenu.classList.remove('open');document.querySelectorAll('.link-style[open]').forEach(positionBlockStyleMenu);},true);
        window.addEventListener('resize',()=>document.querySelectorAll('.link-style[open]').forEach(positionBlockStyleMenu));
        function openStyleMenu(url) {const links=[...document.querySelectorAll('a.inline-link[data-url]')].filter(e=>e.dataset.url===url);if(links.length){showLinkMenu(links[links.length-1],true);return;}const figures=[...document.querySelectorAll('figure.linked-text[data-url]')].filter(e=>e.dataset.url===url);const figure=figures[figures.length-1];figure?.classList.remove('style-dismissed');figure?.querySelector('.link-style')?.setAttribute('open','');}
        function dismissStyleMenu(url) {const figures=[...document.querySelectorAll('figure.linked-text[data-url]')].filter(e=>e.dataset.url===url);figures[figures.length-1]?.classList.add('style-dismissed');}

        function resolveLinkMetadata(url,title,description,favicon,image) {
          document.querySelectorAll('figure.link-chip[data-url]').forEach(figure=>{
            if(figure.dataset.url!==url)return;
            figure.querySelector('.bookmark-title').textContent=title;
            figure.querySelector('.bookmark-description').textContent=description||url;
            const icon=figure.querySelector('.link-favicon');if(favicon){icon.src=favicon;icon.hidden=false;icon.onerror=()=>{icon.hidden=true;};}
            const preview=figure.querySelector('.bookmark-preview');
            const footer=figure.querySelector('.bookmark-host');
            preview.onload=()=>{if(preview.isConnected){preview.hidden=false;figure.classList.add('has-preview-image');footer.textContent=url;}};
            preview.onerror=()=>{preview.hidden=true;figure.classList.remove('has-preview-image');footer.textContent=new URL(url).hostname;};
            if(image){preview.src=image;if(preview.complete&&preview.naturalWidth>0)preview.onload();}
            else{preview.hidden=true;figure.classList.remove('has-preview-image');footer.textContent=new URL(url).hostname;preview.removeAttribute('src');}
          });
          document.querySelectorAll('a.mention-link[data-url]').forEach(link=>{
            if(link.dataset.url!==url)return;
            link.querySelector('.mention-title').textContent=title;
            link.querySelector('.mention-tooltip strong').textContent=title;
            link.querySelector('.mention-tooltip small').textContent=description||url;
            link.setAttribute('aria-label',description?title+' — '+description:title);
            const icon=link.querySelector('.link-favicon');if(favicon){icon.src=favicon;icon.hidden=false;icon.onerror=()=>{icon.hidden=true;};}
          });
        }
        function resolvePreview(index,title) {const link=document.querySelector('[data-preview="'+index+'"]');if(link)link.textContent=title;}
        function resolveEmbed(index,url) {const frame=document.querySelector('[data-embed="'+index+'"]');if(frame&&frame.src!==url)frame.src=url;}
        </script></body></html>
        """
    }
}
