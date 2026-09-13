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

final class MediaNoteView: WKWebView, WKNavigationDelegate {
    var onChange: ((String) -> Void)?
    var onImport: (([URL]) -> Void)?
    private let mediaHandler: NoteMediaHandler
    private let messageProxy: WeakNoteMessageHandler
    private var lastSource: String?
    private var lastID: UUID?
    private var lastSize: CGFloat = 0
    private var lastDark = false
    private var pageID = UUID().uuidString
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
        resolutionTask?.cancel()
        lastSource = note.text; lastID = note.id; lastSize = fontSize; lastDark = dark
        pageID = UUID().uuidString
        mediaHandler.files = Dictionary(uniqueKeysWithValues: note.media.map {
            (Self.mediaURL($0, note: note), (store.attachmentURL($0, noteID: note.id), $0.mediaType))
        })
        loadHTMLString(Self.page(note, fontSize: fontSize, dark: dark, pageID: pageID), baseURL: URL(string: "https://luna.invalid"))
    }
    func suspend() {
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
              body["page"] == pageID, let source = body["source"], source.utf8.count <= 2_000_000 else { return }
        lastSource = body["kind"] == "input" ? source : nil
        onChange?(source)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let source = lastSource else { return }
        let currentPage = pageID
        let urls = NoteEmbeds.blocks(source).compactMap { block -> URL? in
            if case .embed(_, let url) = block { return url }; return nil
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
    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let files = droppedFiles(sender), !files.isEmpty { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let files = droppedFiles(sender), !files.isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let files = droppedFiles(sender), !files.isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let files = droppedFiles(sender), !files.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.callAsyncJavaScript("placeCaret(x, y)", arguments: ["x": point.x, "y": self.isFlipped ? point.y : self.bounds.height - point.y], in: nil, contentWorld: .page)
            self.onImport?(files)
        }
        return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(["https", "about"].contains(url?.scheme ?? "") ? .allow : .cancel)
        } else if navigationAction.navigationType == .linkActivated {
            if let url, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(url?.scheme == "about" || url?.host == "luna.invalid" ? .allow : .cancel) }
    }

    static func page(_ note: Note, fontSize: CGFloat, dark: Bool, pageID: String) -> String {
        let escape = NoteEmbeds.escape
        var html = ""
        var embedIndex = 0
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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(pageID)'; style-src 'unsafe-inline'; img-src luna-media: https:; media-src luna-media: https:; frame-src https:; base-uri 'none'; form-action 'none'">
        <style>
        :root {color-scheme: \(dark ? "dark" : "light");}
        body {margin:0;padding:24px 40px 80px;color:\(dark ? "#cccccc" : "#242833");font:\(fontSize)px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;}
        article {max-width:72ch;margin:auto;} .text {white-space:pre-wrap;overflow-wrap:anywhere;min-height:1.65em;outline:none;}
        .text:empty:before {content:'Write something…';color:\(dark ? "#777d85" : "#858b92");pointer-events:none;}
        .text:empty:not(:focus):not(:last-child):before {content:none;}
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
        document.addEventListener('input',()=>post('input'));
        document.addEventListener('click',e=>{if(e.target.matches('.remove')){e.target.closest('figure').remove();post('structure');}});
        function placeCaret(x,y) {const r=document.caretRangeFromPoint(x,y);if(r&&r.startContainer.parentElement.closest('.text')){const s=getSelection();s.removeAllRanges();s.addRange(r);}}
        function insertSnippet(snippet) {
          const selected=getSelection();let block=selected.anchorNode?.parentElement?.closest('.text');
          if(!block){block=document.querySelector('.text:last-child');if(!block){block=document.createElement('div');block.className='text';block.contentEditable='plaintext-only';block.dataset.block='';document.querySelector('article').append(block);}block.focus();const range=document.createRange();range.selectNodeContents(block);range.collapse(false);selected.removeAllRanges();selected.addRange(range);}
          document.execCommand('insertText',false,snippet);post('structure');
        }
        document.addEventListener('paste',e=>{const text=e.clipboardData.getData('text/plain');const match=text.match(/<iframe\\b[^>]*\\bsrc\\s*=\\s*["'](https:\\/\\/[^"']+)["']/i);let url=match?.[1]||text.trim();try{const parsed=new URL(url);if(parsed.protocol==='https:'&&!parsed.username&&!parsed.password&&!/\\s/.test(url)){e.preventDefault();insertSnippet('\\n[Embed]('+url.replace(/&amp;/g,'&')+')\\n');}}catch{}});
        function resolveEmbed(index,url) {const frame=document.querySelector('[data-embed="'+index+'"]');if(frame&&frame.src!==url)frame.src=url;}
        </script></body></html>
        """
    }
}
