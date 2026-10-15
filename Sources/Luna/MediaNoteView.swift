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

/// Weak bridge keeps closing a note from retaining its web view.
private final class WeakNoteMessageHandler: NSObject, WKScriptMessageHandler {
    weak var view: MediaNoteView?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { view?.receive(message) }
}

/// Saved Live View. ProseMirror owns document edits, selection, and history;
/// this adapter owns native files, recovery delivery, and page lifetime.
final class MediaNoteView: FileDropWebView, WKNavigationDelegate {
    var onChange: ((String) -> Void)?
    private let mediaHandler = NoteMediaHandler()
    private let messageProxy = WeakNoteMessageHandler()
    private var lastSource: String?
    private var lastID: UUID?
    private var pageID = UUID().uuidString
    private var readyPageID: String?
    private var focusOnNextLoad = false
    private var pendingInput: [[String: String]] = []
    private var focusTask: Task<Void, Never>?
    private var requests: [String: Task<Void, Never>] = [:]
    private var queuedStyle: String?
    private var currentAssets: [String: [String: String]] = [:]
    private var lastSize: CGFloat = 0
    private var lastDark = false
    private(set) var acceptsEditorCommands = true

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(mediaHandler, forURLScheme: "luna-media")
        configuration.userContentController.add(messageProxy, name: "note")
        super.init(frame: .zero, configuration: configuration)
        messageProxy.view = self; navigationDelegate = self
        setValue(false, forKey: "drawsBackground"); setAccessibilityLabel("Note editor")
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateAttachments(_ note: Note, store: RecoveryStore) {
        mediaHandler.files = Dictionary(uniqueKeysWithValues: note.media.map {
            (Self.mediaURL($0, note: note), (store.attachmentURL($0, noteID: note.id), $0.mediaType))
        })
        let assets = Self.assets(note)
        currentAssets = assets
        if readyPageID == pageID {
            Task { _ = try? await callAsyncJavaScript("window.lunaEditor.setMedia(media)", arguments: ["media": assets], in: nil, contentWorld: .page) }
        }
    }
    func show(_ note: Note, store: RecoveryStore, fontSize: CGFloat, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        updateAttachments(note, store: store)
        if lastID == note.id, lastSource == note.text {
            guard lastSize != fontSize || lastDark != dark else { return }
            lastSize = fontSize; lastDark = dark
            Task { _ = try? await callAsyncJavaScript("window.lunaEditor?.theme(dark, size)", arguments: ["dark": dark, "size": fontSize], in: nil, contentWorld: .page) }
            return
        }
        requests.values.forEach { $0.cancel() }; requests.removeAll()
        focusTask?.cancel(); focusTask = nil
        if lastID != note.id { pendingInput.removeAll(); focusOnNextLoad = false }
        lastSize = fontSize; lastDark = dark
        lastSource = note.text; lastID = note.id; pageID = UUID().uuidString; readyPageID = nil; acceptsEditorCommands = true
        loadHTMLString(Self.page(note, fontSize: fontSize, dark: dark, pageID: pageID), baseURL: URL(string: "https://luna.invalid"))
    }
    func suspend() {
        requests.values.forEach { $0.cancel() }; requests.removeAll()
        focusTask?.cancel(); focusTask = nil; pendingInput.removeAll(); focusOnNextLoad = false
        pageID = UUID().uuidString; readyPageID = nil; lastSource = nil
        loadHTMLString("", baseURL: nil)
    }
    static func mediaURL(_ attachment: NoteAttachment, note: Note) -> URL {
        URL(string: "luna-media://\(note.id.uuidString.lowercased())/\(attachment.id.uuidString)")!
    }
    private static func assets(_ note: Note) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: note.media.map { ($0.reference, ["url": mediaURL($0, note: note).absoluteString,"type": $0.mediaType,"name": $0.filename]) })
    }
    static func page(_ note: Note, fontSize: CGFloat, dark: Bool, pageID: String) -> String {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Luna_Luna.bundle").path
        let resources = packaged.flatMap { Bundle(path: $0) } ?? Bundle.module
        guard let url = resources.url(forResource: "ProseMirrorEditor", withExtension: "html", subdirectory: "Resources"),
              var html = try? String(contentsOf: url, encoding: .utf8) else { return "Editor resource unavailable" }
        let config: [String: Any] = ["page": pageID,"source": note.text,"dark": dark,"size": fontSize,"media": assets(note)]
        let json = String(data: try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), encoding: .utf8)!
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        html = html.replacingOccurrences(of: "</body>", with: "<script>window.lunaEditor.boot(\(json));</script></body>")
        return html
    }
    func queueStyleMenu(for snippet: String) { queuedStyle = InlineLinks.url(in: snippet)?.absoluteString }
    func insertSnippet(_ snippet: String, showsStyleMenu: Bool = false) {
        pendingInput.append(["key": "snippet","text": snippet,"menu": showsStyleMenu ? "true" : "false"])
        focusEditor()
    }
    func command(_ name: String, text: String = "") {
        pendingInput.append(["key": "command","name": name,"text": text])
        focusEditor()
    }
    func selectAllNote() { command("selectAll") }
    @objc func pasteAsPlainText(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { command("pastePlainText", text: text) }
    }
    @discardableResult func pasteClipboard(plain: Bool = false) -> Bool {
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string) ?? board.string(forType: .html) else { return false }
        command(plain ? "pastePlainText" : "paste", text: text)
        return true
    }
    func formatSelection(_ name: String) { command(name) }
    func focusEditor() {
        focusOnNextLoad = true
        guard readyPageID == pageID, !isLoading, focusTask == nil else { return }
        let current = pageID
        focusTask = Task {
            defer { if pageID == current { focusTask = nil } }
            while pageID == current, !isHidden, !Task.isCancelled {
                let input = pendingInput
                let focused = try? await callAsyncJavaScript("if(window.lunaPage!==page)return false;window.lunaEditor.setMedia(media);return window.lunaEditor.focus(input)",
                    arguments: ["page": current,"input": input,"media": currentAssets], in: nil, contentWorld: .page) as? Bool
                guard pageID == current, focused == true else { return }
                pendingInput.removeFirst(input.count)
                if pendingInput.isEmpty { focusOnNextLoad = false; return }
            }
        }
    }
    var hasPendingEdits: Bool { !pendingInput.isEmpty || focusTask != nil }
    /// Finish ordered native actions before a save, note switch, or quit.
    func flushChanges() async -> Bool {
        guard lastSource != nil else { return true }
        let current = pageID
        for _ in 0..<200 {
            guard pageID == current else { return false }
            if readyPageID == current, !isLoading, !hasPendingEdits {
                guard let source = try? await callAsyncJavaScript("if(window.lunaPage!==page)return null;return window.lunaEditor.source",
                    arguments: ["page": current], in: nil, contentWorld: .page) as? String,
                      pageID == current else { return false }
                if source != lastSource { lastSource = source; onChange?(source) }
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }
    func bufferInputUntilFocused(_ event: NSEvent) -> Bool {
        guard focusOnNextLoad, !isHidden, event.modifierFlags.intersection([.command,.control,.option]).isEmpty,
              let text = event.characters, !text.isEmpty else { return false }
        let key: String
        switch event.keyCode {
        case 36,76: key = "Enter"
        case 51: key = "Backspace"
        case 117: key = "Delete"
        default:
            guard text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) else { return false }
            key = "text"
        }
        pendingInput.append(["key": key,"text": text]); return true
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], body["page"] as? String == pageID,
              let kind = body["kind"] as? String else { return }
        if kind == "input", let source = body["source"] as? String, source.utf8.count <= 2_000_000 {
            lastSource = source; onChange?(source); return
        }
        if kind == "focus" { acceptsEditorCommands = body["editing"] as? Bool ?? true; return }
        if kind == "openMedia", let reference = body["reference"] as? String,
           let file = mediaHandler.files.first(where: { $0.key.lastPathComponent.caseInsensitiveCompare(URL(string: reference)?.lastPathComponent ?? "") == .orderedSame })?.value.0 {
            NSWorkspace.shared.open(file); return
        }
        guard let value = body["url"] as? String, value.utf8.count <= 8192, let url = NoteEmbeds.webURL(value) else { return }
        if kind == "copy" { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); return }
        if kind == "open" { NSWorkspace.shared.open(url); return }
        guard ["metadata","embed"].contains(kind), let session = body["session"] as? String else { return }
        let current = pageID, key = kind + "|" + value
        guard requests[key] == nil else { return }
        requests[key] = Task { [weak self] in
            let payload: [String: String]
            if kind == "metadata" {
                let details = await LinkMetadata.shared.details(for: url)
                payload = ["title": details.title ?? "","description": details.description ?? "","favicon": details.favicon?.absoluteString ?? "","image": details.image?.absoluteString ?? ""]
            } else { payload = ["embedURL": await EmbedResolver.shared.resolve(url).absoluteString] }
            guard !Task.isCancelled, let self, self.pageID == current else { return }
            _ = try? await callAsyncJavaScript("if(window.lunaPage===page)window.lunaEditor.resolve(session,url,payload)",
                arguments: ["page": current,"session": session,"url": value,"payload": payload], in: nil, contentWorld: .page)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard lastSource != nil else { return }; readyPageID = pageID
        if focusOnNextLoad { focusEditor() }
        if let url = queuedStyle { queuedStyle = nil; command("showURL", text: url) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if action.targetFrame?.isMainFrame == false { decisionHandler(["https","http","about"].contains(url?.scheme ?? "") ? .allow : .cancel) }
        else if action.navigationType == .linkActivated {
            if let url, ["https","http","mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; decisionHandler(.cancel)
        } else { decisionHandler(url?.scheme == "about" || url?.host == "luna.invalid" ? .allow : .cancel) }
    }
}
