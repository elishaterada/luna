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
        lastSource = nil
        loadHTMLString("", baseURL: nil)
    }
    static func mediaURL(_ attachment: NoteAttachment, note: Note) -> URL {
        URL(string: "luna-media://\(note.id.uuidString.lowercased())/\(attachment.id.uuidString)")!
    }
    func insertSnippet(_ snippet: String) {
        Task { try? await callAsyncJavaScript("insertSnippet(snippet)", arguments: ["snippet": snippet], in: nil, contentWorld: .page) }
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String],
              body["page"] == pageID else { return }
        if body["kind"] == "paste", let value = body["value"] {
            if let choice = URLPasteChoice.choose(value) {
                if let snippet = choice.snippet { insertSnippet(snippet) }
            } else { insertSnippet(value) }
            return
        }
        guard let source = body["source"], source.utf8.count <= 2_000_000 else { return }
        lastSource = body["kind"] == "input" ? source : nil
        onChange?(source)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let source = lastSource else { return }
        let currentPage = pageID
        let urls = NoteEmbeds.blocks(source).compactMap { block -> URL? in
            if case .embed(_, let url) = block { return url }; return nil
        }
        let previews = NoteEmbeds.blocks(source).compactMap { block -> URL? in
            if case .link(_, let url, _, true) = block { return url }; return nil
        }
        metadataTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (Int, String?).self) { group in
                for (index, url) in previews.enumerated() {
                    group.addTask { (index, await LinkMetadata.shared.title(for: url)) }
                }
                for await (index, title) in group {
                    guard !Task.isCancelled, let self, self.pageID == currentPage else { group.cancelAll(); return }
                    if let title {
                        _ = try? await self.callAsyncJavaScript("resolvePreview(index, title)", arguments: ["index": index, "title": title], in: nil, contentWorld: .page)
                    }
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
      const block=selection.anchorNode?.parentElement?.closest('.text');
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

    static func page(_ note: Note, fontSize: CGFloat, dark: Bool, pageID: String) -> String {
        let escape = NoteEmbeds.escape
        var html = ""
        var embedIndex = 0
        var previewIndex = 0
        let blocks = NoteEmbeds.blocks(note.text)
        func textBlock(_ text: String, spacer: Bool = false) -> String {
            "<div class=\"text\" contenteditable=\"plaintext-only\" spellcheck=\"false\" data-block data-spacer=\"\(spacer)\">\(escape(text))</div>"
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
                let title = preview ? (url.host ?? "Website") : label
                let previewAttribute = preview ? " data-preview=\"\(previewIndex)\"" : ""
                if preview { previewIndex += 1 }
                html += "<figure class=\"\(preview ? "link-chip" : "linked-text")\" data-block data-source=\"\(escape(source))\"><a\(previewAttribute) href=\"\(escape(url.absoluteString))\" target=\"_blank\">\(escape(title)) ↗</a>\(preview ? "<small>" + escape(url.absoluteString) + "</small>" : "")<button class=\"remove\" aria-label=\"Remove link\"></button></figure>"
            case .embed(let source, let url):
                let value = escape(url.absoluteString)
                html += """
                <figure data-block data-source="\(escape(source))"><iframe data-embed="\(embedIndex)" src="\(value)" title="\(escape(url.host ?? "Embedded content"))" sandbox="allow-scripts allow-same-origin allow-presentation" allow="fullscreen; autoplay; encrypted-media; picture-in-picture" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe><figcaption><a href="\(value)" target="_blank">\(escape(url.host ?? "Open original")) ↗</a><span> · Open the original if this site cannot be embedded</span></figcaption><button class="remove" aria-label="Remove embed"></button></figure>
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
        body {box-sizing:border-box;min-height:100vh;margin:0;padding:24px 40px 80px;color:\(dark ? "#cccccc" : "#242833");font:\(fontSize)px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;}
        article {max-width:72ch;margin:auto;} .text {white-space:pre-wrap;overflow-wrap:anywhere;min-height:1.65em;outline:none;}
        .text:empty:before {content:'Write something…';color:\(dark ? "#777d85" : "#858b92");pointer-events:none;}
        .text:empty:not(:focus):not(:last-child):before {content:none;}
        .link-chip {border:1px solid #8884;border-radius:10px;padding:12px 16px;} .link-chip small {display:block;font-size:12px;opacity:.65;overflow-wrap:anywhere;}
        figure {position:relative;margin:20px 0;padding:0;} img,video {display:block;max-width:100%;max-height:580px;border-radius:8px;}
        audio {width:100%;} iframe {display:block;width:100%;height:380px;border:1px solid #8883;border-radius:8px;background:#fff;}
        figcaption {font-size:11px;opacity:.7;margin-top:6px;overflow-wrap:anywhere;} a {color:inherit;} .remove {position:absolute;right:8px;top:8px;border:0;border-radius:50%;width:26px;height:26px;background:#222c;color:white;padding:0;box-sizing:border-box;appearance:none;cursor:pointer;opacity:0;}
        .remove::before,.remove::after {content:'';position:absolute;left:50%;top:50%;width:13px;height:2px;background:currentColor;border-radius:1px;pointer-events:none;transform:translate(-50%,-50%) rotate(45deg);}
        .remove::after {transform:translate(-50%,-50%) rotate(-45deg);}
        figure:hover .remove, .remove:focus-visible {opacity:1;} ::selection {background:#19f9d838;}
        </style></head><body><article>\(html)</article>
        <script nonce="\(pageID)">
        const page = '\(pageID)';
        function source() {return [...document.querySelectorAll('[data-block]')].filter(e=>e.dataset.spacer!=='true'||e.innerText!=='').map(e=>e.dataset.source ?? e.innerText.replace(/\\r/g,'')).join('\\n');}
        function post(kind) {window.webkit.messageHandlers.note.postMessage({page,kind,source:source()});}
        \(listScript)
        document.addEventListener('input',()=>post('input'));
        document.addEventListener('click',e=>{if(e.target.matches('.remove')){e.target.closest('figure').remove();post('structure');}});
        document.addEventListener('mousedown',event=>{
          if(event.button!==0 || !event.target.matches('html,body,article'))return;
          const article=document.querySelector('article');
          let last=article.lastElementChild;
          if(last && event.clientY<last.getBoundingClientRect().bottom)return;
          event.preventDefault();
          if(!last?.matches('.text')){
            last=document.createElement('div');last.className='text';last.contentEditable='plaintext-only';
            last.dataset.block='';last.dataset.spacer='true';article.append(last);
          }
          last.focus({preventScroll:true});
          const range=document.createRange();range.selectNodeContents(last);range.collapse(false);
          const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
        });
        function placeCaret(x,y) {const r=document.caretRangeFromPoint(x,y);if(r&&r.startContainer.parentElement.closest('.text')){const s=getSelection();s.removeAllRanges();s.addRange(r);}}
        function insertSnippet(snippet) {
          const selected=getSelection();let block=selected.anchorNode?.parentElement?.closest('.text');
          if(!block){block=document.querySelector('.text:last-child');if(!block){block=document.createElement('div');block.className='text';block.contentEditable='plaintext-only';block.dataset.block='';document.querySelector('article').append(block);}block.focus();const range=document.createRange();range.selectNodeContents(block);range.collapse(false);selected.removeAllRanges();selected.addRange(range);}
          document.execCommand('insertText',false,snippet);post('structure');
        }
        document.addEventListener('paste',e=>{const text=e.clipboardData.getData('text/plain');if(/^(https?:\\/\\/\\S+)$/.test(text.trim())||/<iframe/i.test(text)){e.preventDefault();window.webkit.messageHandlers.note.postMessage({page,kind:'paste',value:text});}});

        function resolvePreview(index,title) {const link=document.querySelector('[data-preview="'+index+'"]');if(link)link.textContent=title+' ↗';}
        function resolveEmbed(index,url) {const frame=document.querySelector('[data-embed="'+index+'"]');if(frame&&frame.src!==url)frame.src=url;}
        </script></body></html>
        """
    }
}
