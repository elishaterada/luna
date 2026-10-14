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
    private var focusOnNextLoad = false
    private var pendingInput: [[String: String]] = []
    private var focusTask: Task<Void, Never>?
    private let mediaHandler: NoteMediaHandler
    private let messageProxy: WeakNoteMessageHandler
    private var lastSource: String?
    private var lastID: UUID?
    private var lastSize: CGFloat = 0
    private var lastDark = false
    private var pageID = UUID().uuidString
    private var readyPageID: String?
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
        setAccessibilityLabel("Note editor")
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ note: Note, store: RecoveryStore, fontSize: CGFloat, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard lastSource != note.text || lastID != note.id || lastSize != fontSize || lastDark != dark else { return }
        metadataTask?.cancel()
        resolutionTask?.cancel()
        focusTask?.cancel(); focusTask = nil
        if lastID != note.id { pendingInput.removeAll(); focusOnNextLoad = false }
        lastSource = note.text; lastID = note.id; lastSize = fontSize; lastDark = dark
        pageID = UUID().uuidString
        readyPageID = nil
        mediaHandler.files = Dictionary(uniqueKeysWithValues: note.media.map {
            (Self.mediaURL($0, note: note), (store.attachmentURL($0, noteID: note.id), $0.mediaType))
        })
        loadHTMLString(Self.page(note, fontSize: fontSize, dark: dark, pageID: pageID), baseURL: URL(string: "https://luna.invalid"))
    }
    func suspend() {
        metadataTask?.cancel()
        resolutionTask?.cancel()
        mentionCaretOnNextLoad = nil
        focusOnNextLoad = false
        focusTask?.cancel(); focusTask = nil
        pendingInput.removeAll()
        pageID = UUID().uuidString
        readyPageID = nil
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
        let noteID = lastID
        Task {
            // A new live note may still be loading when a paste or media import finishes.
            for _ in 0..<100 {
                guard lastID == noteID, lastSource != nil, !isHidden else { return }
                if readyPageID == pageID, !isLoading {
                    let inserted = try? await callAsyncJavaScript("""
                        if (typeof page === 'undefined' || page !== expectedPage) return false;
                        insertSnippet(snippet, showsStyleMenu); return true;
                        """, arguments: ["expectedPage": pageID, "snippet": snippet, "showsStyleMenu": showsStyleMenu],
                        in: nil, contentWorld: .page) as? Bool
                    // Do not retry an indeterminate result and risk inserting the same text twice.
                    if inserted != false { return }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
    func selectAllNote() {
        Task { _ = try? await callAsyncJavaScript("selectAllNote()", in: nil, contentWorld: .page) }
    }
    @objc func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let currentPage = pageID
        Task {
            for _ in 0..<100 {
                guard pageID == currentPage, !isHidden else { return }
                if readyPageID == currentPage, !isLoading {
                    _ = try? await callAsyncJavaScript("""
                        if (page !== expectedPage) return false;
                        if (document.activeElement?.matches('input,textarea')) {
                            return document.execCommand('insertText', false, text);
                        }
                        if (replaceWholeNote(text)) return true;
                        if (!focusTextEditor()) return false;
                        insertListText(text); post('input'); return true;
                        """, arguments: ["expectedPage": currentPage, "text": text], in: nil, contentWorld: .page)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
    func formatSelection(_ command: String) {
        Task { _ = try? await callAsyncJavaScript("""
            const selection=getSelection();
            if (!selection?.rangeCount || selection.isCollapsed) return false;
            formatRange=selection.getRangeAt(0).cloneRange();
            return applySelectionFormat(command);
            """, arguments: ["command": command], in: nil, contentWorld: .page) }
    }
    func focusEditor() {
        focusOnNextLoad = true
        guard readyPageID == pageID, !isLoading, focusTask == nil else { return }
        let currentPage = pageID
        focusTask = Task {
            defer { if pageID == currentPage { focusTask = nil } }
            while pageID == currentPage, !isHidden, !Task.isCancelled {
                let input = pendingInput
                let focused = try? await callAsyncJavaScript("""
                    if (page !== expectedPage || !focusTextEditor()) return false;
                    replayPendingInput(input); return true;
                    """, arguments: ["expectedPage": currentPage, "input": input], in: nil, contentWorld: .page) as? Bool
                guard pageID == currentPage, focused == true else { return }
                pendingInput.removeFirst(input.count)
                if pendingInput.isEmpty { focusOnNextLoad = false; return }
            }
        }
    }
    func bufferInputUntilFocused(_ event: NSEvent) -> Bool {
        guard focusOnNextLoad, !isHidden,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let text = event.characters, !text.isEmpty else { return false }
        let key: String
        switch event.keyCode {
        case 36, 76: key = "Enter"
        case 51: key = "Backspace"
        case 117: key = "Delete"
        default:
            guard text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) else { return false }
            key = "text"
        }
        pendingInput.append(["key": key, "text": text])
        return true
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
        readyPageID = pageID
        let currentPage = pageID
        if let mentionCaretOnNextLoad {
            self.mentionCaretOnNextLoad = nil
            focusOnNextLoad = false
            Task { _ = try? await callAsyncJavaScript("focusAfterMention(url, index)",
                arguments: ["url": mentionCaretOnNextLoad.url, "index": mentionCaretOnNextLoad.index],
                in: nil, contentWorld: .page) }
        } else if focusOnNextLoad {
            focusEditor()
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
    let listMarkerEdit = 0;
    function layoutListRows(block) {
      block.style.removeProperty('--list-indent-parent');
      for(const row of [block,...block.querySelectorAll('div,p')]) {
        row.style.removeProperty('--list-indent');
        const marker=[...row.querySelectorAll('.list-marker')].find(marker=>marker.closest('div,p')===row);
        if(!marker)continue;
        const range=document.createRange();range.setStart(row,0);range.setEndBefore(marker);
        // A range before the marker can include empty editing containers with
        // full-width rectangles. Measure only portable leading whitespace.
        const whitespace=range.toString().replace(/\u200B/g,'').match(/[ \t]*$/)[0];
        const context=document.createElement('canvas').getContext('2d');context.font=getComputedStyle(block).font;
        const space=context.measureText(' ').width,tab=space*parseFloat(getComputedStyle(block).tabSize||'8');
        let indent=0;for(const character of whitespace)indent=character==='\t'?(Math.floor(indent/tab)+1)*tab:indent+space;
        const width=(indent+parseFloat(getComputedStyle(block).fontSize)*1.5)+'px';
        row.style.setProperty('--list-indent',width);
        if(row===block)block.style.setProperty('--list-indent-parent',width);
      }
    }
    function markerHTML(marker,id='') {
      const bullet=/^[-*+•]$/.test(marker);
      return '<span class="list-marker'+(bullet?' bullet-marker':'')+'" data-prefix="'+marker+' "'+(id?' data-list-edit="'+id+'"':'')+'>'+(bullet?'•':marker)+'</span>\u200B';
    }
    function normalizeListCaret() {
      const selection=getSelection();
      if(!selection?.isCollapsed||!selection.rangeCount||document.body.classList.contains('composing'))return;
      const node=selection.anchorNode;
      let marker=node?.parentElement?.closest('.list-marker');
      if(!marker&&node?.nodeType===Node.TEXT_NODE&&selection.anchorOffset===0)marker=node.previousSibling;
      if(!marker&&node?.nodeType===Node.ELEMENT_NODE)marker=node.childNodes[selection.anchorOffset-1];
      if(!marker?.matches?.('.list-marker')||!/^(?:[-*+•☐☑]|\d+\.)$/.test(marker.textContent))return;
      // A cross-line deletion can leave the caret at the end of the marker and remove its body anchor.
      let text=marker.nextSibling;
      if(text?.nodeType!==Node.TEXT_NODE){text=document.createTextNode('\u200B');marker.after(text);}
      else if(!text.textContent.startsWith('\u200B'))text.insertData(0,'\u200B');
      const caret=document.createRange();caret.setStart(text,1);caret.collapse(true);
      selection.removeAllRanges();selection.addRange(caret);
    }
    document.addEventListener('selectionchange',normalizeListCaret);
    document.addEventListener('beforeinput',normalizeListCaret);
    function restoreListBodyCaret() {
      const selection=getSelection();if(!selection?.rangeCount||selection.isCollapsed)return;
      const node=selection.anchorNode,block=(node.nodeType===Node.ELEMENT_NODE?node:node.parentElement)?.closest('.text');
      if(!block)return;
      const range=selection.getRangeAt(0),selected=range.toString().replace(/\u200B/g,'');
      const marker=[...block.querySelectorAll('.list-marker')].find(marker=>
        /^(?:[-*+•☐☑]|\d+\.)$/.test(marker.textContent)&&selected===marker.textContent&&range.intersectsNode(marker));
      if(!marker)return;
      // Undo can select the restored prefix. Subsequent typing belongs in its body.
      let anchor=marker.nextSibling;
      if(anchor?.nodeType!==Node.TEXT_NODE){anchor=document.createTextNode('\u200B');marker.after(anchor);}
      else if(!anchor.textContent.startsWith('\u200B'))anchor.insertData(0,'\u200B');
      const caret=document.createRange();caret.setStart(anchor,1);caret.collapse(true);
      selection.removeAllRanges();selection.addRange(caret);
    }
    function restoreListSource(root) {
      root.querySelectorAll('.list-marker').forEach(marker=>{
        const text=marker.textContent;
        // Only an intact visual bullet can use the original Markdown prefix.
        // If its editable glyph changed, preserve that text instead of stale metadata.
        const original=marker.dataset.prefix;
        const source=text==='•'&&/^[-*+•] $/.test(original||'')?original[0]:text;
        marker.replaceWith(document.createTextNode(source+(/^(?:[-*+•☐☑]|\d+\.)$/.test(text)?' ':'')));
      });
    }
    function insertListText(text) {
      const escaped=document.createElement('div');escaped.textContent=text;
      let fenced=false,styled=false;
      let html=escaped.innerHTML.split('\n').map(line=>{
        if(/^[ \t]*(```|~~~)/.test(line)){fenced=!fenced;return line;}
        if(fenced)return line;
        return line.replace(/^([ \t]*)([-*+•☐☑]|\d+\.) /,(_,indent,marker)=>{
          styled=true;return indent+markerHTML(marker);
        });
      }).join('<br>');
      const rich=styled&&text.startsWith('\n');
      const anchor=getSelection().anchorNode;
      const row=(anchor?.nodeType===Node.ELEMENT_NODE?anchor:anchor?.parentElement)?.closest('div,p');
      if(rich&&row?.closest('.text')) {
        // A BR fragment escapes a native paragraph and creates two line boundaries.
        document.execCommand('insertParagraph');html=html.slice(4);
      }
      document.execCommand(rich?'insertHTML':'insertText',false,rich?html:text);
    }
    function decorateListMarkers(block,undoable=false) {
      // The portable separator belongs to the atomic prefix, not the editable content.
      const wasFormatting=formattingList;formattingList=true;
      let atStart=true,fenced=false;
      function visit(parent) {
        for(const node of [...parent.childNodes]) {
          if(node.nodeType===Node.ELEMENT_NODE) {
            if(node.matches('br')){atStart=true;continue;}
            const row=node.matches('div,p');if(row)atStart=true;
            if(node.matches('.list-marker,a'))atStart=false;else visit(node);
            if(row)atStart=true;
            continue;
          }
          if(node.nodeType!==Node.TEXT_NODE)continue;
          const value=node.textContent,parts=value.split('\n');let offset=0,matches=[];
          for(let i=0;i<parts.length;i++) {
            const part=parts[i];
            if(atStart && /^[ \t\u200B]*(```|~~~)/.test(part))fenced=!fenced;
            const match=atStart&&!fenced?part.match(/^([ \t\u200B]*)([-*+•☐☑]|\d+\.) /):null;
            if(match)matches.push({start:offset+match[1].length,end:offset+match[0].length,marker:match[2]});
            if(part.replace(/\u200B/g,'').length)atStart=false;if(i<parts.length-1)atStart=true;
            offset+=part.length+1;
          }
          if(!matches.length)continue;
          if(undoable) {
            let target=node;
            for(const match of matches.reverse()) {
              const selection=getSelection(),anchor=selection.anchorNode,anchorOffset=selection.anchorOffset;
              const range=document.createRange();range.setStart(target,match.start);range.setEnd(target,match.end);
              selection.removeAllRanges();selection.addRange(range);
              const id=String(++listMarkerEdit);
              document.execCommand('insertHTML',false,markerHTML(match.marker,id));
              const span=block.querySelector('[data-list-edit="'+id+'"]');
              if(!span)continue;
              const caret=document.createRange();
              // WebKit treats offset zero after an inline span as the end of that span.
              // Put the caret after the invisible anchor so typing stays in body text.
              if(anchor===target && anchorOffset>=match.end)caret.setStart(span.nextSibling,anchorOffset-match.end+(span.nextSibling.textContent.startsWith('\u200B')?1:0));
              else if(anchor===target)caret.setStart(span.previousSibling||span.firstChild,anchorOffset);
              else caret.setStart(anchor,anchorOffset);
              caret.collapse(true);selection.removeAllRanges();selection.addRange(caret);
              target=span.previousSibling;
            }
            continue;
          }
          const fragment=document.createDocumentFragment();let start=0;
          function append(end,marker) {
            if(end<=start)return;
            const text=document.createTextNode(value.slice(start,end));
            if(marker){const template=document.createElement('template');template.innerHTML=markerHTML(marker.marker);fragment.append(template.content);}
            else fragment.append(text);
            start=end;
          }
          for(const match of matches){append(match.start);append(match.end,match);}append(value.length);
          fragment.normalize();
          node.replaceWith(fragment);
        }
      }
      visit(block);
      formattingList=wasFormatting;
      layoutListRows(block);
    }
    function currentLine() {
      const selection=getSelection();
      const node=selection.anchorNode;
      const block=(node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement)?.closest('.text');
      if(!block || !selection.isCollapsed)return null;
      const range=selection.getRangeAt(0).cloneRange();range.selectNodeContents(block);range.setEnd(selection.anchorNode,selection.anchorOffset);
      // Range.toString omits WebKit's DIV/BR line boundaries and includes Mention tooltips.
      const fragment=document.createElement('div');fragment.className='text';fragment.append(range.cloneContents());
      restoreListSource(fragment);
      fragment.querySelectorAll('a.mention-link').forEach(link=>link.replaceWith(document.createTextNode(link.querySelector('.mention-title').textContent)));
      fragment.style.cssText='position:absolute;opacity:0;pointer-events:none;left:-10000px;';
      const before=paragraphText(fragment).replace(/[\r\u200B]/g,'');
      const start=before.lastIndexOf('\n')+1;
      if((before.slice(0,start).match(/^\s*(```|~~~)/gm)||[]).length%2)return null;
      return {block, prefix:before.slice(start), start};
    }
    function replaceBefore(count,text) {
      const selection=getSelection();
      const node=selection.anchorNode;
      const marker=node?.nodeType===Node.TEXT_NODE&&node.textContent.slice(0,selection.anchorOffset).replace(/\u200B/g,'')===''?node.previousSibling:null;
      if(marker?.matches?.('.list-marker')) {
        const range=document.createRange();range.setStartBefore(marker);range.setEnd(node,selection.anchorOffset);
        selection.removeAllRanges();selection.addRange(range);
        formattingList=true;document.execCommand('insertHTML',false,'<span>\u200B</span>');formattingList=false;return;
      }
      for(let i=0;i<count;i++)selection.modify('extend','backward','character');
      formattingList=true;insertListText(text);formattingList=false;
      const block=selection.anchorNode?.parentElement?.closest('.text');if(block)decorateListMarkers(block,true);
    }
    document.addEventListener('input',e=>{
      if(e.inputType?.startsWith('history')){restoreListBodyCaret();return;}
      if(formattingList)return;
      const line=currentLine();if(!line)return;
      let formatted=line.prefix.replace(/^([ \t]*)(?:[-*+•] )?\[([ xX])\] /,(_,indent,check)=>indent+(check===' '?'☐ ':'☑ '))
        .replace(/^([ \t]*)(\d+)\) /,'$1$2. ');
      if(formatted!==line.prefix)replaceBefore(line.prefix.length,formatted);
      else if(/^([ \t]*)([-*+•☐☑]|\d+\.) $/.test(line.prefix))decorateListMarkers(line.block,true);
    });
    function indentLiveList(outdent) {
      const selection=getSelection();if(!selection?.rangeCount)return false;
      const range=selection.getRangeAt(0),node=range.startContainer;
      const block=(node.nodeType===Node.ELEMENT_NODE?node:node.parentElement)?.closest('.text');
      if(!block||!block.contains(range.endContainer))return false;
      let markers=[...block.querySelectorAll('.list-marker')];
      if(selection.isCollapsed) {
        if(!currentLine()?.prefix.match(/^([ \t]*)([-*+•☐☑]|\d+\.) /))return false;
        const before=range.cloneRange();before.selectNodeContents(block);before.setEnd(range.startContainer,range.startOffset);
        markers=markers.slice(before.cloneContents().querySelectorAll('.list-marker').length-1).slice(0,1);
      } else markers=markers.filter(marker=>{
        const line=document.createRange();line.setStartBefore(marker);line.setEndAfter(marker);
        let next=marker.nextSibling;
        while(next&&!next.matches?.('br,div,p,.list-marker')){line.setEndAfter(next);next=next.nextSibling;}
        return range.compareBoundaryPoints(Range.END_TO_START,line)<0&&range.compareBoundaryPoints(Range.START_TO_END,line)>0;
      });
      if(!markers.length)return false;
      function offset(container,index) {const r=document.createRange();r.selectNodeContents(block);r.setEnd(container,index);return r.toString().length;}
      let start=offset(range.startContainer,range.startOffset),end=offset(range.endContainer,range.endOffset);
      const collapsed=selection.isCollapsed;
      const clone=block.cloneNode(true),allMarkers=[...block.querySelectorAll('.list-marker')],clonedMarkers=[...clone.querySelectorAll('.list-marker')];
      let changed=false;
      for(const marker of markers.reverse()) {
        const previous=marker.previousSibling;
        const match=previous?.nodeType===Node.TEXT_NODE?previous.textContent.match(/(?:^|\n)([ \t\u200B]*)$/):null;
        const indent=match?.[1]||'',visible=indent.replace(/\u200B/g,''),anchors=indent.replace(/[ \t]/g,'');
        const removed=outdent?(visible.startsWith('\t')?1:Math.min(visible.match(/^ */)[0].length,liveTabWidth)):0;
        const replacement=anchors+(outdent?visible.slice(removed):liveIndent+visible);
        if(replacement===indent)continue;
        const edit=document.createRange();edit.setStartBefore(marker);edit.collapse(true);
        if(match){edit.setStart(previous,previous.length-indent.length);edit.setEnd(previous,previous.length);}
        const editStart=offset(edit.startContainer,edit.startOffset),editEnd=offset(edit.endContainer,edit.endOffset),delta=replacement.length-indent.length;
        const target=clonedMarkers[allMarkers.indexOf(marker)];
        if(match)target.previousSibling.textContent=previous.textContent.slice(0,previous.length-indent.length)+replacement;
        else target.before(document.createTextNode(replacement));
        if(start>editStart||collapsed&&start===editStart)start=Math.max(editStart,start+delta);
        if(end>=editEnd)end=Math.max(editStart,end+delta);
        changed=true;
      }
      if(!changed)return true;
      const indexes=markers.map(marker=>allMarkers.indexOf(marker)),firstIndex=Math.min(...indexes),lastIndex=Math.max(...indexes);
      function prefixRange(first,last) {
        const r=document.createRange(),previous=first.previousSibling;
        const match=previous?.nodeType===Node.TEXT_NODE?previous.textContent.match(/(?:^|\n)([ \t\u200B]*)$/):null;
        if(match)r.setStart(previous,previous.length-match[1].length);else r.setStartBefore(first);
        r.setEndAfter(last);
        if(last.nextSibling?.nodeType===Node.TEXT_NODE&&last.nextSibling.textContent.startsWith('\u200B'))r.setEnd(last.nextSibling,1);
        return r;
      }
      const fragment=document.createElement('div');fragment.append(prefixRange(clonedMarkers[firstIndex],clonedMarkers[lastIndex]).cloneContents());
      // Keep this transaction inside the touched lines; replacing an entire paragraph tree creates trailing rows.
      const rows=[...fragment.querySelectorAll('div,p')];
      rows.forEach(row=>{if(row.lastChild?.nodeName==='BR')row.lastChild.remove();});
      for(const row of rows.reverse()) {
        const inline=document.createDocumentFragment(),previous=row.previousSibling,next=row.nextSibling;
        if(previous&&previous.nodeName!=='BR'&&previous.lastChild?.nodeName!=='BR'&&!previous.textContent.endsWith('\n'))inline.append(document.createElement('br'));
        inline.append(...row.childNodes);
        if(next&&inline.lastChild?.nodeName!=='BR'&&!next.matches?.('div,p,br')&&!next.textContent.startsWith('\n'))inline.append(document.createElement('br'));
        row.replaceWith(inline);
      }
      formattingList=true;
      const edit=prefixRange(allMarkers[firstIndex],allMarkers[lastIndex]);selection.removeAllRanges();selection.addRange(edit);
      document.execCommand('insertHTML',false,fragment.innerHTML);formattingList=false;
      function point(position) {
        const walker=document.createTreeWalker(block,NodeFilter.SHOW_TEXT);let text,last;
        while(text=walker.nextNode()){last=text;if(position<=text.length)return [text,position];position-=text.length;}
        return last?[last,last.length]:[block,0];
      }
      const restored=document.createRange();restored.setStart(...point(start));restored.setEnd(...point(end));
      selection.removeAllRanges();selection.addRange(restored);block.focus({preventScroll:true});normalizeListCaret();post('input');return true;
    }
    document.addEventListener('keydown',e=>{
      if(e.defaultPrevented||e.key!=='Tab'||e.isComposing||e.metaKey||e.ctrlKey||e.altKey||!document.activeElement?.closest('.text'))return;
      e.preventDefault();
      if(!indentLiveList(e.shiftKey)&&!e.shiftKey){document.execCommand('insertText',false,liveIndent);post('input');}
    });
    document.addEventListener('keydown',e=>{
      if(!e.defaultPrevented&&!e.isComposing)normalizeListCaret();
      if(!e.defaultPrevented&&e.key==='Backspace'&&!e.isComposing&&!e.altKey&&!e.metaKey&&!e.ctrlKey&&!e.shiftKey) {
        const insideMarker=getSelection().anchorNode?.parentElement?.closest('.list-marker');
        const line=insideMarker?null:currentLine(),match=line?.prefix.match(/^([ \t]*)([-*+•☐☑]|\d+\.) $/);
        if(match){e.preventDefault();replaceBefore(line.prefix.length,match[1]);post('input');return;}
        const selection=getSelection(),node=selection.anchorNode;
        if(selection.isCollapsed&&node?.nodeType===Node.TEXT_NODE&&selection.anchorOffset>0&&/^\u200B+$/.test(node.textContent.slice(0,selection.anchorOffset))&&!node.previousSibling?.matches?.('.list-marker')) {
          const caret=document.createRange();caret.setStart(node,0);caret.collapse(true);
          selection.removeAllRanges();selection.addRange(caret);
        }

      }
      if(e.defaultPrevented||e.key!=='Enter'||e.shiftKey||e.isComposing)return;
      const line=currentLine();if(!line)return;
      const match=line.prefix.match(/^([ \t]*)([-*+•☐☑]|\d+\.) (.*)$/);if(!match)return;
      e.preventDefault();
      if(!match[3].trim())replaceBefore(line.prefix.length,'');
      else {
        const marker=/^\d/.test(match[2])?(Number.parseInt(match[2])+1)+'.':/^[-*+•]$/.test(match[2])?match[2]:'☐';
        // Each continued item needs its own paragraph for independent hanging indentation.
        const prefix=match[1]+marker+' ';
        formattingList=true;insertListText('\n'+prefix);formattingList=false;
      }
      post('input');
    });
    document.addEventListener('click',e=>{
      if(!e.target.closest('.text'))return;
      const prefix=e.target.closest('.list-marker');
      if(prefix&&['☐','☑'].includes(prefix.textContent)) {
        const range=document.createRange();range.selectNode(prefix);getSelection().removeAllRanges();getSelection().addRange(range);
        formattingList=true;document.execCommand('insertHTML',false,markerHTML(prefix.textContent==='☐'?'☑':'☐'));formattingList=false;
        post('input');return;
      }
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
    let wholeNoteSelectionText=null,wholeNoteSelectionRange=null,wholeNoteEditID=0;
    function isWholeNoteSelected() {
      const selection=getSelection();
      if(wholeNoteSelectionText===null||!wholeNoteSelectionRange||!selection?.rangeCount)return false;
      const range=selection.getRangeAt(0);
      return range.compareBoundaryPoints(Range.START_TO_START,wholeNoteSelectionRange)===0&&
        range.compareBoundaryPoints(Range.END_TO_END,wholeNoteSelectionRange)===0;
    }
    const wholeNoteEdits=[];
    document.addEventListener('input',e=>{
      if(!e.inputType?.startsWith('history'))return;
      for(const record of [...wholeNoteEdits].reverse()) {
        if(!record.block.isConnected)continue;
        const applied=(record.block.textContent.match(/^\u200B*/)?.[0]||'')===record.anchor;
        if(applied)record.others.forEach(child=>child.remove());
        else if(record.applied&&e.inputType==='historyUndo') {
          let previous=record.block;record.others.forEach(child=>{previous.after(child);previous=child;});
        }
        record.applied=applied;
      }
      post('input');
    });
    function paragraphText(root,placeholders=true) {
      let result='',previousBlock=false,previousEmptyRow=false,hasPrevious=false;
      for(const node of root.childNodes) {
        const row=node.nodeType===Node.ELEMENT_NODE&&node.matches('div,p');
        if(row) {
          if(hasPrevious&&(previousEmptyRow||!result.endsWith('\n')))result+='\n';
          const value=paragraphText(node,placeholders);result+=value;previousEmptyRow=!value;previousBlock=true;hasPrevious=true;
        } else {
          const value=node.nodeType===Node.TEXT_NODE?node.textContent.replace(/\u200B/g,''):
            node.nodeName==='BR'?(placeholders&&node===root.lastChild?'':'\n'):paragraphText(node,placeholders);
          if(!value)continue;
          if(previousBlock&&!value.startsWith('\n')&&(previousEmptyRow||!result.endsWith('\n')))result+='\n';
          result+=value;previousBlock=false;previousEmptyRow=false;hasPrevious=true;
        }
      }
      return result;
    }
    function textSource(block) {
      const clone=block.cloneNode(true);
      const editable=block.matches('[contenteditable="true"]');
      // WebKit can leave two terminal BRs: one editing placeholder and one
      // line terminator. Neither represents a new paragraph in saved source.
      let tail=clone.lastChild;
      while(tail?.nodeType===Node.ELEMENT_NODE&&tail.matches('div,p'))tail=tail.lastChild;
      if(editable&&tail?.nodeName==='BR')tail.remove();
      restoreListSource(clone);
      function restoreInlineSource(element) {
        [...element.children].forEach(restoreInlineSource);
        if(element.matches('a.inline-link')) {
          const a=element;
          const label=a.classList.contains('mention-link')?'Mention':
            a.textContent===a.dataset.url?'URL':a.textContent.replaceAll('\\','\\\\').replaceAll(']','\\]');
          const url=a.dataset.url.replaceAll('(','%28').replaceAll(')','%29');
          a.replaceWith(document.createTextNode('['+label+']('+url+')'));
        } else if(element.matches('b,strong,i,em,s,strike,del,code')||isInlineCode(element)) {
          let marker=element.dataset.inlineDelimiter;
          if(!marker)marker=element.matches('b,strong')?'**':element.matches('i,em')?'*':element.matches('s,strike,del')?'~~':'`';
          const value=element.textContent.replace(/\u200B/g,'');
          if(isInlineCode(element)) {
            const longest=Math.max(0,...[...value.matchAll(/`+/g)].map(match=>match[0].length));
            if(marker.length<=longest)marker='`'.repeat(longest+1);
          }
          const spaces=element.matches('b,strong,i,em')?value.match(/^(\s*)([\s\S]*?)(\s*)$/):['','','',''];
          const content=element.matches('b,strong,i,em')?spaces[2]:value;
          element.replaceWith(document.createTextNode(spaces[1]+(content?marker+content+marker:'')+spaces[3]));
        }
      }
      restoreInlineSource(clone);
      return paragraphText(clone,editable).replace(/[\r\u200B]/g,'');
    }
    function mentionIndexBefore(element,url) {
      return [...document.querySelectorAll('a.mention-link[data-url]')].filter(link=>
        link.dataset.url===url && !!(link.compareDocumentPosition(element)&Node.DOCUMENT_POSITION_FOLLOWING)).length;
    }
    function placeCaretAfterMention(link) {
      const block=link?.closest('.text');if(!block)return;
      block.focus({preventScroll:true});
      const range=document.createRange();let tail=link.nextSibling;
      if(tail?.nodeType!==Node.TEXT_NODE){tail=document.createTextNode('\u200B');link.after(tail);}
      else if(!tail.textContent.startsWith('\u200B'))tail.insertData(0,'\u200B');
      range.setStart(tail,1);
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
        link.dataset.url=next;link.href=next;link.classList.remove('mention-link');link.textContent=title;post('inlineLink');hideLinkMenu();placeCaretAfterMention(link);return;
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
      const focused=document.activeElement;
      if(focused?.matches('input,textarea')){focused.select();return;}
      hideLinkMenu();activeSlashMenu.classList.remove('open');
      const article=document.querySelector('article'),range=document.createRange();
      const first=article.querySelector('.text');
      first?.focus({preventScroll:true});
      if(article.children.length===1&&first)range.selectNodeContents(first);
      else range.selectNodeContents(article);
      getSelection().removeAllRanges();getSelection().addRange(range);
      wholeNoteSelectionText=getSelection().toString();wholeNoteSelectionRange=getSelection().getRangeAt(0).cloneRange();
      article.classList.add('whole-note-selected');
    }
    document.addEventListener('keydown',e=>{
      if(!e.metaKey||e.altKey||e.ctrlKey||e.shiftKey||e.key.toLowerCase()!=='a'||
         !document.activeElement?.closest('article'))return;
      e.preventDefault();selectAllNote();
    });
    document.addEventListener('selectionchange',()=>{
      if(wholeNoteSelectionText!==null&&!isWholeNoteSelected()){
        wholeNoteSelectionText=null;wholeNoteSelectionRange=null;document.querySelector('article').classList.remove('whole-note-selected');
      }
    });
    document.addEventListener('pointerdown',e=>{if(e.target.closest('article')){
      wholeNoteSelectionText=null;wholeNoteSelectionRange=null;document.querySelector('article').classList.remove('whole-note-selected');
    }},true);
    document.addEventListener('copy',e=>{
      const selection=getSelection();
      if(isWholeNoteSelected()) {
        e.clipboardData.setData('text/plain',source());e.preventDefault();return;
      }
      if(selection.isCollapsed||!selection.rangeCount)return;
      const fragment=selection.getRangeAt(0).cloneContents();
      if(!fragment.querySelector('.list-marker,b,strong,i,em,s,strike,del,code,a.inline-link'))return;
      const block=document.createElement('div');block.className='text';block.append(fragment);
      e.clipboardData.setData('text/plain',textSource(block));e.preventDefault();
    });
    document.addEventListener('cut',e=>{
      if(!isWholeNoteSelected())return;
      e.clipboardData.setData('text/plain',source());e.preventDefault();replaceWholeNote('');
    });
    document.addEventListener('keydown',e=>{
      if(!e.metaKey||e.altKey||e.ctrlKey||e.shiftKey||e.key.toLowerCase()!=='c'||
         !isWholeNoteSelected())return;
      e.preventDefault();window.webkit.messageHandlers.note.postMessage({page,kind:'copySelection',source:source()});
    });
    function replaceWholeNote(value) {
      const article=document.querySelector('article'),selection=getSelection();
      if(!isWholeNoteSelected())return false;
      wholeNoteSelectionText=null;wholeNoteSelectionRange=null;article.classList.remove('whole-note-selected');
      hideLinkMenu();activeSlashMenu.classList.remove('open');
      const block=article.children.length===1?article.querySelector('.text'):null;
      if(block) {
        block.focus({preventScroll:true});const range=document.createRange();range.selectNodeContents(block);
        selection.removeAllRanges();selection.addRange(range);
        if(value)document.execCommand('insertText',false,value);
        else {
          // Clearing from a marker otherwise carries its enlarged font and nowrap
          // into new typing. Keep an ordinary body anchor in the same Undo edit.
          const style=getComputedStyle(block);
          document.execCommand('insertHTML',false,'<span style="font-size:'+style.fontSize+';font-weight:'+style.fontWeight+';white-space:pre-wrap;text-align:left">\u200B</span>');
        }
      } else {
        const first=article.querySelector('.text');if(!first)return false;
        // A source-excluded anchor identifies the native text transaction without splitting typing's Undo group.
        const record={anchor:'\u200B'.repeat(++wholeNoteEditID+1),block:first,others:[...article.children].filter(child=>child!==first),applied:true};
        wholeNoteEdits.push(record);
        first.focus({preventScroll:true});const range=document.createRange();range.selectNodeContents(first);
        selection.removeAllRanges();selection.addRange(range);
        document.execCommand('insertText',false,record.anchor+value);
        record.others.forEach(child=>child.remove());
        first.focus({preventScroll:true});
      }
      post('input');return true;
    }
    document.addEventListener('keydown',e=>{
      if(e.isComposing||e.metaKey||e.ctrlKey||e.altKey)return;
      const deletion=['Backspace','Delete','Del'].includes(e.key);
      const value=deletion?'':e.key==='Enter'?'\n':e.key.length===1?e.key:null;
      if(value!==null&&replaceWholeNote(value))e.preventDefault();
    });
    const slashCommands=[
      {group:'Basic blocks',name:'Text',keys:['text','paragraph'],insert:''},
      {group:'Basic blocks',name:'Heading 1',keys:['h1','heading'],insert:'# '},
      {group:'Basic blocks',name:'Heading 2',keys:['h2','heading'],insert:'## '},
      {group:'Basic blocks',name:'Quote',keys:['quote'],insert:'> '},
      {group:'Lists',name:'Bulleted list',keys:['bullet','list'],insert:'- '},
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

    private static let selectionScript = #"""
    const formatMenu=document.getElementById('format-popover');
    const selectionPaint=document.getElementById('selection-paint');
    let formatRange=null,selectionDragging=false,formatDismissed=false,formatFrame=0,selectionWindowActive=true;
    function isInlineCode(element){return !!element&&(element.matches('code')||element.style.fontFamily.includes('ui-monospace'));}
    function containingInlineCode(node) {
      let element=node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement;
      while(element&&!element.matches('.text')){if(isInlineCode(element))return element;element=element.parentElement;}
      return null;
    }
    function selectedBodyRanges(range) {
      const ranges=[],walker=document.createTreeWalker(document.querySelector('article'),NodeFilter.SHOW_TEXT);
      while(walker.nextNode()) {
        const node=walker.currentNode;
        if(!node.parentElement.closest('.text')||node.parentElement.closest('.list-marker,.mention-tooltip')||!range.intersectsNode(node))continue;
        let start=node===range.startContainer?range.startOffset:0,end=node===range.endContainer?range.endOffset:node.length;
        // Invisible typing anchors and literal indentation before a marker are
        // editing structure, rather than selected item content.
        if(node.nextSibling?.matches?.('.list-marker')&&!node.textContent.trim())continue;
        while(start<end&&node.textContent[start]==='\u200B')start++;
        while(end>start&&node.textContent[end-1]==='\u200B')end--;
        if(start===end)continue;
        const part=document.createRange();part.setStart(node,start);part.setEnd(node,end);ranges.push(part);
      }
      return ranges;
    }
    function hideFormatMenu(){formatMenu.classList.remove('open');formatMenu.replaceChildren();}
    function formatButtons() {
      formatMenu.innerHTML='<button data-format="bold" aria-label="Bold" title="Bold (⌘B)"><b>B</b></button><button data-format="italic" aria-label="Italic" title="Italic (⌘I)"><i>I</i></button><button data-format="strikeThrough" aria-label="Strikethrough" title="Strikethrough"><s>S</s></button><button data-format="code" aria-label="Inline code" title="Inline code (⌘⇧C)"><span class="code-symbol">&lt;/&gt;</span></button><span class="format-divider"></span><button data-format="link" aria-label="Add link" title="Add link (⌘K)"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="m10 13 4-4M8 15l-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m2 3 1-1a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0" transform="translate(1 1)"/></svg></button>';
      for(const button of formatMenu.querySelectorAll('[data-format]')) {
        const command=button.dataset.format;
        button.setAttribute('aria-pressed',String(command==='code'?!!containingInlineCode(getSelection().anchorNode):
          ['bold','italic','strikeThrough'].includes(command)&&document.queryCommandState(command)));
      }
    }
    function refreshSelectionUI() {
      selectionPaint.replaceChildren();document.body.classList.remove('body-selection');
      const selection=getSelection();
      // Focusing a URL input collapses WebKit's document selection. Keep the
      // saved editor range until the link form is submitted or dismissed.
      const editingLink=!!formatMenu.querySelector('form');
      const retainedRange=editingLink&&formatRange?.startContainer.isConnected&&formatRange.endContainer.isConnected;
      if(!selectionWindowActive||document.body.classList.contains('composing')||(editingLink?!retainedRange:!selection?.rangeCount||selection.isCollapsed)){hideFormatMenu();formatRange=null;return;}
      const range=editingLink?formatRange:selection.getRangeAt(0),parts=selectedBodyRanges(range);
      if(!parts.length){hideFormatMenu();return;}
      const focused=formatMenu.contains(document.activeElement);
      document.body.classList.add('body-selection');
      const rectangles=parts.flatMap(part=>[...part.getClientRects()]).filter(rect=>rect.width>0&&rect.height>0);
      for(const rect of rectangles) {
        const mark=document.createElement('span');mark.style.cssText=`left:${rect.left}px;top:${rect.top}px;width:${rect.width}px;height:${rect.height}px;`;
        selectionPaint.append(mark);
      }
      if(editingLink) {
        const visible=rectangles.filter(rect=>rect.bottom>0&&rect.top<innerHeight);
        if(!visible.length){hideFormatMenu();return;}
        positionPopover(formatMenu,visible.at(-1));return;
      }
      if(focused)return;
      const start=(range.startContainer.nodeType===Node.ELEMENT_NODE?range.startContainer:range.startContainer.parentElement)?.closest('.text');
      const end=(range.endContainer.nodeType===Node.ELEMENT_NODE?range.endContainer:range.endContainer.parentElement)?.closest('.text');
      if(selectionDragging||formatDismissed||!start||start!==end||!rectangles.length||activeLinkMenu.classList.contains('open')||activeSlashMenu.classList.contains('open')){hideFormatMenu();return;}
      formatRange=range.cloneRange();formatButtons();
      const visible=rectangles.filter(rect=>rect.bottom>0&&rect.top<innerHeight);
      if(!visible.length){hideFormatMenu();return;}
      const last=visible.at(-1);positionPopover(formatMenu,last);
    }
    function scheduleSelectionUI(){cancelAnimationFrame(formatFrame);formatFrame=requestAnimationFrame(refreshSelectionUI);}
    function restoreFormatSelection() {
      if(!formatRange?.startContainer.isConnected||!formatRange.endContainer.isConnected)return false;
      const block=(formatRange.startContainer.nodeType===Node.ELEMENT_NODE?formatRange.startContainer:formatRange.startContainer.parentElement)?.closest('.text');
      if(!block)return false;
      const parts=selectedBodyRanges(formatRange);if(!parts.length)return false;
      formatRange.setStart(parts[0].startContainer,parts[0].startOffset);
      formatRange.setEnd(parts.at(-1).endContainer,parts.at(-1).endOffset);
      block.focus({preventScroll:true});getSelection().removeAllRanges();getSelection().addRange(formatRange.cloneRange());return true;
    }
    function applySelectionFormat(command) {
      if(!restoreFormatSelection())return false;
      if(command==='code') {
        const range=getSelection().getRangeAt(0),code=containingInlineCode(range.startContainer);
        if(code&&code===containingInlineCode(range.endContainer)) {
          const full=document.createRange();full.selectNode(code);getSelection().removeAllRanges();getSelection().addRange(full);
          document.execCommand('insertHTML',false,code.innerHTML);
        } else {
          const clone=range.cloneContents();
          // Code is an inline format: keep paragraph boundaries and markers.
          const walker=document.createTreeWalker(clone,NodeFilter.SHOW_TEXT),nodes=[];
          while(walker.nextNode())if(!walker.currentNode.parentElement?.closest('.list-marker,a'))nodes.push(walker.currentNode);
          for(const node of nodes) {
            const value=node.textContent;if(!value.replace(/[\s\u200B]/g,''))continue;
            const code=document.createElement('code');code.textContent=value;node.replaceWith(code);
          }
          const container=document.createElement('div');container.append(clone);
          document.execCommand('insertHTML',false,container.innerHTML);
        }
      } else {
        // Native inline commands otherwise put later list prefixes inside bold
        // wrappers. Treat only the marker as atomic for this editing transaction.
        const markers=[...document.querySelectorAll('.list-marker')];
        markers.forEach(marker=>marker.contentEditable='false');
        document.execCommand('styleWithCSS',false,false);document.execCommand(command);
        document.querySelectorAll('.list-marker').forEach(marker=>marker.removeAttribute('contenteditable'));
      }
      post('input');formatRange=getSelection().rangeCount?getSelection().getRangeAt(0).cloneRange():null;
      scheduleSelectionUI();return true;
    }
    function showSelectionLink() {
      formatMenu.innerHTML='<form><label for="selection-link-url">Link URL</label><input id="selection-link-url" type="text" inputmode="url" placeholder="https://example.com" required><div class="format-link-actions"><button type="button" data-format="cancel-link">Cancel</button><button type="submit">Save link</button></div></form>';
      const input=formatMenu.querySelector('input');input.focus();
      formatMenu.querySelector('form').addEventListener('submit',event=>{
        event.preventDefault();const url=validLink(input.value.trim());
        if(!url){input.setCustomValidity('Enter a valid http or https URL.');input.reportValidity();return;}
        if(!restoreFormatSelection())return;
        document.querySelectorAll('.list-marker').forEach(marker=>marker.contentEditable='false');
        document.execCommand('createLink',false,url);
        document.querySelectorAll('.list-marker').forEach(marker=>marker.removeAttribute('contenteditable'));
        document.querySelectorAll('.text a:not(.inline-link)').forEach(link=>{link.classList.add('inline-link');link.dataset.url=link.href;});
        post('inlineLink');hideFormatMenu();scheduleSelectionUI();
      });
      input.addEventListener('input',()=>input.setCustomValidity(''));
      scheduleSelectionUI();
    }
    formatMenu.addEventListener('mousedown',event=>{if(event.target.closest('button'))event.preventDefault();});
    formatMenu.addEventListener('click',event=>{
      const command=event.target.closest('[data-format]')?.dataset.format;if(!command)return;
      if(command==='link'){showSelectionLink();return;}
      if(command==='cancel-link'){restoreFormatSelection();formatButtons();scheduleSelectionUI();return;}
      applySelectionFormat(command);
    });
    document.addEventListener('selectionchange',()=>{
      const range=getSelection().rangeCount?getSelection().getRangeAt(0):null;
      if(!formatDismissed||!range||!formatRange||range.compareBoundaryPoints(Range.START_TO_START,formatRange)!==0||range.compareBoundaryPoints(Range.END_TO_END,formatRange)!==0)formatDismissed=false;
      scheduleSelectionUI();
    });
    document.addEventListener('pointerdown',event=>{
      if(formatMenu.contains(event.target))return;
      selectionDragging=true;formatDismissed=false;hideFormatMenu();
    });
    document.addEventListener('pointerup',()=>{selectionDragging=false;scheduleSelectionUI();});
    document.addEventListener('input',()=>{document.querySelectorAll('.list-marker').forEach(marker=>marker.removeAttribute('contenteditable'));scheduleSelectionUI();});
    document.addEventListener('scroll',scheduleSelectionUI,true);window.addEventListener('resize',scheduleSelectionUI);
    window.addEventListener('blur',()=>{selectionWindowActive=false;hideFormatMenu();selectionPaint.replaceChildren();document.body.classList.remove('body-selection');});
    window.addEventListener('focus',()=>{selectionWindowActive=true;scheduleSelectionUI();});
    document.addEventListener('compositionstart',()=>{hideFormatMenu();selectionPaint.replaceChildren();});
    document.addEventListener('keydown',event=>{
      if(event.key==='Escape'&&formatMenu.classList.contains('open')){event.preventDefault();formatDismissed=true;restoreFormatSelection();hideFormatMenu();return;}
      // macOS can omit buttons from native Tab traversal. Keep all link-form
      // controls reachable without changing the user's system preference.
      if(event.key==='Tab'&&!event.metaKey&&!event.ctrlKey&&!event.altKey&&formatMenu.querySelector('form')&&formatMenu.contains(document.activeElement)) {
        event.preventDefault();const controls=[...formatMenu.querySelectorAll('input,button')],index=controls.indexOf(document.activeElement);
        controls[(index+(event.shiftKey?controls.length-1:1))%controls.length].focus();return;
      }
      if(event.altKey&&event.key==='F10'&&formatMenu.classList.contains('open')){event.preventDefault();formatMenu.querySelector('button')?.focus();return;}
      if(formatMenu.contains(document.activeElement)&&document.activeElement.matches('button')&&['ArrowLeft','ArrowRight'].includes(event.key)) {
        event.preventDefault();const buttons=[...formatMenu.querySelectorAll('button')],index=buttons.indexOf(document.activeElement);
        buttons[(index+(event.key==='ArrowRight'?1:buttons.length-1))%buttons.length].focus();return;
      }
      if(formatMenu.contains(document.activeElement))return;
      if(event.altKey||event.ctrlKey||!event.metaKey)return;
      const key=event.key.toLowerCase(),command=key==='b'?'bold':key==='i'?'italic':key==='c'&&event.shiftKey?'code':key==='k'?'link':null;
      const selection=getSelection();if(!command||!selection?.rangeCount||selection.isCollapsed)return;
      const range=selection.getRangeAt(0),start=range.startContainer.parentElement?.closest('.text'),end=range.endContainer.parentElement?.closest('.text');
      if(!start||start!==end)return;
      event.preventDefault();formatRange=range.cloneRange();
      if(command==='link'){refreshSelectionUI();showSelectionLink();}else applySelectionFormat(command);
    });
    """#

    static func page(_ note: Note, fontSize: CGFloat, dark: Bool, pageID: String) -> String {
        let escape = NoteEmbeds.escape
        let steadyCaret = Bundle.main.object(forInfoDictionaryKey: "LunaDevelopmentBuild") as? Bool == true
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
            let content = text.isEmpty ? "" : InlineLinks.html(text).components(separatedBy: "\n")
                .map { "<div>\($0.isEmpty ? "<br>" : $0)</div>" }.joined()
            return "<div class=\"text\" contenteditable=\"true\" spellcheck=\"false\" data-block data-spacer=\"\(spacer)\">\(content)</div>"
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
        .text,.text div,.text p {text-align:left !important;}
        .text div,.text p {min-height:1.8em;margin:0;}
        /* Empty rows need their BR in layout for native Up/Down caret stops. */
        .text div > br:last-child:not(:first-child),.text p > br:last-child:not(:first-child) {display:none;}
        .text,.text div,.text p {box-sizing:border-box;padding-left:var(--list-indent,0px);}
        .text div,.text p {--list-indent:0px;}
        .text > div,.text > p {margin-left:calc(-1 * var(--list-indent-parent,0px));}
        .list-marker {display:inline-block;width:1.25em;margin-left:calc(-1 * var(--list-indent,0px));margin-right:.25em;text-align:right;white-space:nowrap;overflow-wrap:normal;font-variant-numeric:tabular-nums;}
        .list-marker {font-weight:400;font-style:normal;text-decoration:none;user-select:none;-webkit-user-select:none;}
        .list-marker:empty {display:none;}
        .bullet-marker {--bullet-scale:1.45;font-size:calc(1em * var(--bullet-scale));width:calc(1.25em / var(--bullet-scale));margin-right:calc(.25em / var(--bullet-scale));line-height:0;text-align:center;}
        .text {caret-color:transparent;} body.composing .text {caret-color:auto;}
        #text-caret {position:fixed;width:1.5px;background:\(dark ? "#19f9d8" : "#00796b");pointer-events:none;z-index:2;animation:\(steadyCaret ? "none" : "caret-blink 1s linear infinite");}
        #text-caret[hidden] {display:none;} @keyframes caret-blink {0%,49% {opacity:1;} 50%,100% {opacity:0;}}
        #caret-guide {position:fixed;top:0;bottom:0;border-left:1px dashed #f7a65c;pointer-events:none;z-index:1;}
        #caret-readout {position:fixed;bottom:8px;left:40px;font:11px/1.4 monospace;background:#242833;color:#fff;padding:3px 6px;pointer-events:none;z-index:3;}
        @media (prefers-reduced-motion:reduce) {#text-caret {animation:none;}}
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
        article.whole-note-selected > figure {background-color:#19f9d838;}
        body.body-selection article ::selection {background:transparent;}
        #selection-paint {position:fixed;inset:0;pointer-events:none;z-index:0;}
        #selection-paint span {position:fixed;background:#19f9d838;}
        article {position:relative;z-index:1;}
        .text code {font-family:ui-monospace,SFMono-Regular,monospace;font-size:.88em;background:#8882;border-radius:3px;padding:1px 3px;}
        #format-popover {min-width:0;width:max-content;padding:4px;user-select:none;}
        #format-popover.open {display:flex;align-items:center;gap:2px;}
        #format-popover button {display:flex;justify-content:center;align-items:center;width:34px;height:34px;padding:0;text-align:center;}
        #format-popover button[aria-pressed=true] {background:#19f9d825;color:\(dark ? "#19f9d8" : "#087769");}
        #format-popover button:focus-visible {outline:2px solid \(dark ? "#19f9d8" : "#087769");outline-offset:-2px;}
        #format-popover .code-symbol {font:12px ui-monospace,SFMono-Regular,monospace;}
        .format-divider {height:20px;width:1px;background:#8884;margin:0 3px;}
        #format-popover form {width:min(250px,calc(100vw - 40px));padding:5px;}
        #format-popover label {display:block;padding:2px 0 4px;}
        #format-popover .format-link-actions {display:flex;justify-content:flex-end;gap:4px;}
        #format-popover .format-link-actions button {width:auto;padding:0 9px;}
        </style></head><body><article>\(html)</article><div id="selection-paint" aria-hidden="true"></div><div id="format-popover" class="editor-popover" role="toolbar" aria-label="Format selection"></div><div id="text-caret" hidden aria-hidden="true"></div><div id="caret-guide" hidden aria-hidden="true"></div><div id="caret-readout" hidden aria-hidden="true"></div><div id="link-popover" class="editor-popover" role="dialog" aria-label="Link options"></div><div id="slash-popover" class="editor-popover" role="listbox" aria-label="Insert block"></div>
        <script nonce="\(pageID)">
        const page = '\(pageID)';
        const liveTabWidth=\(EditorPreferences.tabWidth),liveIndent='\(EditorPreferences.useTabs ? "\\t" : String(repeating: " ", count: EditorPreferences.tabWidth))';
        function source() {return [...document.querySelectorAll('[data-block]')].filter(e=>e.dataset.spacer!=='true'||e.innerText!=='').map(e=>e.dataset.source ?? textSource(e)).join('\\n');}
        function post(kind, extra={}) {document.querySelectorAll('.text').forEach(layoutListRows);window.webkit.messageHandlers.note.postMessage({page,kind,source:source(),...extra});}
        \(listScript)
        \(editorScript)
        \(selectionScript)
        document.querySelectorAll('.text').forEach(block=>decorateListMarkers(block));
        let caretDebug=false,caretFrame=0,caretWindowActive=true;
        function updateTextCaret() {
          const indicator=document.getElementById('text-caret'),selection=getSelection();
          const guide=document.getElementById('caret-guide'),readout=document.getElementById('caret-readout');
          const node=selection?.anchorNode,block=(node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement)?.closest('.text');
          indicator.hidden=true;guide.hidden=true;readout.hidden=true;
          if(!caretWindowActive||!selection?.isCollapsed||!selection.rangeCount||!block||document.activeElement!==block||document.body.classList.contains('composing'))return;
          if(document.querySelector('.editor-popover.open'))return;
          const range=selection.getRangeAt(0).cloneRange();
          if(node.nodeType===Node.ELEMENT_NODE) {
            let before=node.childNodes[selection.anchorOffset-1];
            // Native typing leaves a terminal BR placeholder in the last row.
            // Measure the preceding content (including inline styles) instead
            // of the hidden BR, while retaining the actual editing selection.
            while(before?.nodeType===Node.ELEMENT_NODE) {
              if(before.nodeName==='BR') {
                if(before===before.parentNode.lastChild&&before.previousSibling){before=before.previousSibling;continue;}
                range.setStartBefore(before);range.collapse(true);break;
              }
              if(!before.lastChild){range.selectNodeContents(before);range.collapse(false);break;}
              before=before.lastChild;
            }
            if(before?.nodeType===Node.TEXT_NODE){range.setStart(before,before.textContent.length);range.collapse(true);}
          }
          // WebKit may split a glyph's advance between the visible letter and a
          // following zero-width anchor. Measure past anchors without changing
          // the editing selection, so the drawn caret reaches the glyph's edge.
          const geometryNode=range.startContainer;
          if(geometryNode.nodeType===Node.TEXT_NODE) {
            let offset=range.startOffset;
            while(geometryNode.textContent[offset]==='\\u200B')offset++;
            range.setStart(geometryNode,offset);range.collapse(true);
          }
          let rect=range.getBoundingClientRect();const style=getComputedStyle(block),height=parseFloat(style.fontSize);
          if(!rect.height) {
            const element=range.startContainer.nodeType===Node.ELEMENT_NODE?range.startContainer:range.startContainer.parentElement;
            const row=element?.closest('div,p');
            if(row?.closest('.text')===block&&row.textContent.replace(/\\u200B/g,'')==='') {
              const bounds=row.getBoundingClientRect();rect={left:bounds.left,top:bounds.top,height:parseFloat(style.lineHeight)};
            } else if(block.textContent==='') {
              const bounds=block.getBoundingClientRect();rect={left:bounds.left,top:bounds.top,height:parseFloat(style.lineHeight)};
            }
          }
          if(!rect.height)return;
          indicator.style.left=rect.left+'px';indicator.style.top=(rect.top+(rect.height-height)/2)+'px';indicator.style.height=height+'px';
          indicator.hidden=false;
          if(caretDebug) {
            guide.style.left=rect.left+'px';guide.hidden=false;
            const preceding=node.nodeType===Node.TEXT_NODE?node.textContent.slice(0,selection.anchorOffset).replace(/\\u200B/g,'').slice(-12):'';
            readout.textContent='Caret after '+JSON.stringify(preceding)+' · x '+rect.left.toFixed(1)+' · y '+parseFloat(indicator.style.top).toFixed(1);
            readout.hidden=false;
          }
        }
        function refreshTextCaret() {
          updateTextCaret();
          // WebKit can finalize selection/layout after an edit's input listeners.
          // Refresh again before painting without queuing a frame for every event.
          if(!caretFrame)caretFrame=requestAnimationFrame(()=>{caretFrame=0;updateTextCaret();});
        }
        function hideTextCaret() {
          ['text-caret','caret-guide','caret-readout'].forEach(id=>document.getElementById(id).hidden=true);
          if(caretFrame){cancelAnimationFrame(caretFrame);caretFrame=0;}
        }
        document.addEventListener('selectionchange',refreshTextCaret);
        document.addEventListener('input',refreshTextCaret);
        document.addEventListener('keyup',refreshTextCaret);
        document.addEventListener('focusin',refreshTextCaret);
        document.addEventListener('focusout',hideTextCaret);
        document.addEventListener('scroll',refreshTextCaret,true);window.addEventListener('resize',refreshTextCaret);
        window.addEventListener('blur',()=>{caretWindowActive=false;hideTextCaret();});
        window.addEventListener('focus',()=>{caretWindowActive=true;refreshTextCaret();});
        document.addEventListener('keydown',e=>{
          if(\(steadyCaret)&&e.ctrlKey&&e.altKey&&!e.metaKey&&e.code==='KeyD') {
            e.preventDefault();caretDebug=!caretDebug;refreshTextCaret();
          }
        });
        document.addEventListener('compositionstart',()=>{document.body.classList.add('composing');updateTextCaret();});
        document.addEventListener('compositionend',()=>{document.body.classList.remove('composing');updateTextCaret();});
        document.addEventListener('input',e=>{const block=e.target.closest('.text');if(block){if(e.inputType?.startsWith('delete')&&block.textContent==='')block.replaceChildren();if(!formattingList&&!e.inputType?.startsWith('history'))decorateListMarkers(block,true);post('input');updateSlashMenu();}});
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
          if(event.button===0 && event.target.matches('.text,.text div,.text p')){
            const block=event.target.closest('.text');let row=event.target===block?block.lastElementChild:event.target;
            if(!row?.matches('div,p'))row=block;
            const link=row.lastElementChild;
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
        function focusTextEditor() {
          const block=document.querySelector('.text');if(!block)return false;
          const selection=getSelection();
          const selected=(selection.anchorNode?.nodeType===Node.ELEMENT_NODE?selection.anchorNode:selection.anchorNode?.parentElement)?.closest('.text');
          if(selected){selected.focus({preventScroll:true});return true;}
          block.focus({preventScroll:true});
          const range=document.createRange();range.selectNodeContents(block.firstElementChild?.matches('div,p')?block.firstElementChild:block);range.collapse(true);
          selection.removeAllRanges();selection.addRange(range);normalizeListCaret();return true;
        }
        function replayPendingInput(input) {
          for(const value of input) {
            if(value.key==='text'){document.execCommand('insertText',false,value.text);continue;}
            const event=new KeyboardEvent('keydown',{key:value.key,bubbles:true,cancelable:true});
            document.dispatchEvent(event);
            if(!event.defaultPrevented)document.execCommand(value.key==='Enter'?'insertParagraph':value.key==='Backspace'?'delete':'forwardDelete');
          }
        }
        function insertSnippet(snippet, showsStyleMenu=false) {
          const selected=getSelection();const node=selected.anchorNode;let block=(node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement)?.closest('.text');
          if(!block){block=document.querySelector('.text:last-child');if(!block){block=document.createElement('div');block.className='text';block.contentEditable='true';block.dataset.block='';document.querySelector('article').append(block);}block.focus();const range=document.createRange();range.selectNodeContents(block);range.collapse(false);selected.removeAllRanges();selected.addRange(range);}
          if(showsStyleMenu){const match=snippet.match(/^\\[URL\\]\\((https?:\\/\\/[^)]+)\\)$/);if(match){const range=selected.getRangeAt(0);range.deleteContents();const a=document.createElement('a');a.className='inline-link';a.dataset.url=match[1];a.href=match[1];a.textContent=match[1];range.insertNode(a);range.setStartAfter(a);range.collapse(true);selected.removeAllRanges();selected.addRange(range);post('inlineLink');showLinkMenu(a,true);return;}}
          insertListText(snippet);post('structure');
        }
        document.addEventListener('paste',e=>{if(!e.target.closest('.text'))return;const text=e.clipboardData.getData('text/plain');e.preventDefault();const whole=wholeNoteSelectionText!==null;if(whole&&!/^(https?:\\/\\/\\S+)$/.test(text.trim())&&!/<iframe/i.test(text)&&replaceWholeNote(text))return;replaceWholeNote('');if(/^(https?:\\/\\/\\S+)$/.test(text.trim())||/<iframe/i.test(text)){window.webkit.messageHandlers.note.postMessage({page,kind:'paste',value:text});}else{insertListText(text);post('input');}});
        document.addEventListener('scroll',event=>{
          // Long title/URL inputs scroll horizontally when focused or typed in.
          // Those internal scrolls do not move the note or its anchored menu.
          if(activeLinkMenu.contains(event.target))return;
          hideLinkMenu();activeSlashMenu.classList.remove('open');document.querySelectorAll('.link-style[open]').forEach(positionBlockStyleMenu);
        },true);
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
