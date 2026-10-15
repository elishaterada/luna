import AppKit
import WebKit
import UniformTypeIdentifiers

private final class PrototypeLinkHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ProseMirrorPrototype?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

/// Throwaway, memory-only editor evaluation. It receives a string copy and has no recovery bridge.
final class ProseMirrorPrototype: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    private let webView: WKWebView
    private let source: String
    private let fontSize: CGFloat
    private let linkHandler: PrototypeLinkHandler
    private var requests: [String: Task<Void, Never>] = [:]
    private(set) var acceptsEditorCommands = true

    init(source: String, fontSize: CGFloat) {
        self.source = source
        self.fontSize = fontSize
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        linkHandler = PrototypeLinkHandler()
        configuration.userContentController.add(linkHandler, name: "prototypeLinks")
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = ProseMirrorPrototypeWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        linkHandler.owner = self
        window.title = "ProseMirror trial — Luna"
        window.minSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false
        window.appearance = EditorPreferences.nsAppearance
        window.contentView = webView
        window.delegate = self
        window.center()
        window.editor = webView
        window.command = { [weak self] name in self?.command(name) }
        window.pastePlainText = { [weak self] in self?.pastePlainText() }
        window.acceptsEditorCommands = { [weak self] in self?.acceptsEditorCommands ?? false }
        webView.setAccessibilityLabel("ProseMirror trial")
        webView.navigationDelegate = self
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Luna_Luna.bundle").path
        let resources = packaged.flatMap { Bundle(path: $0) } ?? Bundle.module
        if let url = resources.url(forResource: "ProseMirrorPrototype", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String, let session = body["session"] as? String else { return }
        if kind == "focus" { acceptsEditorCommands = body["editing"] as? Bool ?? true; return }
        if kind == "export", let source = body["source"] as? String, source.utf8.count <= 2_000_000, let window {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "ProseMirror trial.md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try source.write(to: url, atomically: true, encoding: .utf8) }
                catch { NSAlert(error: error).runModal() }
            }
            return
        }
        if kind == "import", let window {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let data = try Data(contentsOf: url)
                    guard data.count <= 2_000_000, let source = String(data: data, encoding: .utf8) else {
                        throw NSError(domain: "LunaPrototype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a UTF-8 Markdown file smaller than 2 MB."])
                    }
                    Task { _ = try? await self?.webView.callAsyncJavaScript("window.lunaPrototype.openMarkdown(source)",
                        arguments: ["source": source], in: nil, contentWorld: .page) }
                } catch { NSAlert(error: error).runModal() }
            }
            return
        }
        guard let value = body["url"] as? String, value.utf8.count <= 8192, let url = NoteEmbeds.webURL(value) else { return }
        if kind == "copy" { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); return }
        if kind == "open" { NSWorkspace.shared.open(url); return }
        guard ["metadata", "embed"].contains(kind) else { return }
        let key = session + "|" + kind + "|" + value
        guard requests[key] == nil else { return }
        requests[key] = Task { [weak self] in
            let payload: [String: String]
            if kind == "metadata" {
                let details = await LinkMetadata.shared.details(for: url)
                payload = ["title": details.title ?? "", "description": details.description ?? "",
                           "favicon": details.favicon?.absoluteString ?? "", "image": details.image?.absoluteString ?? ""]
            } else {
                let resolved = await EmbedResolver.shared.resolve(url)
                payload = ["embedURL": resolved.absoluteString]
            }
            guard !Task.isCancelled, let self else { return }
            _ = try? await webView.callAsyncJavaScript("window.lunaPrototype.resolve(session, url, payload)",
                arguments: ["session": session, "url": value, "payload": payload], in: nil, contentWorld: .page)
        }
    }
    func windowWillClose(_ notification: Notification) { requests.values.forEach { $0.cancel() }; webView.stopLoading() }

    func command(_ name: String) {
        Task { _ = try? await webView.callAsyncJavaScript("window.lunaPrototype.command(name)",
            arguments: ["name": name], in: nil, contentWorld: .page) }
    }
    func pastePlainText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        Task { _ = try? await webView.callAsyncJavaScript("window.lunaPrototype.command('pastePlainText', text)",
            arguments: ["text": text], in: nil, contentWorld: .page) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let build = Bundle.main.object(forInfoDictionaryKey: "LunaDevelopmentBuild") as? Bool == true
            ? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" : ""
        Task {
            _ = try? await webView.callAsyncJavaScript("window.lunaPrototype.boot(source, dark, size, build)",
                arguments: ["source": source, "dark": dark, "size": fontSize, "build": build], in: nil, contentWorld: .page)
            window?.makeFirstResponder(webView)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(["https", "http", "about"].contains(navigationAction.request.url?.scheme ?? "") ? .allow : .cancel)
        } else {
            let url = navigationAction.request.url
            decisionHandler(navigationAction.navigationType != .linkActivated && (url?.isFileURL == true || url?.scheme == "about") ? .allow : .cancel)
        }
    }
}

/// Route native menu shortcuts to ProseMirror's history and commands in this window only.
private final class ProseMirrorPrototypeWindow: NSWindow {
    weak var editor: WKWebView?
    var command: ((String) -> Void)?
    var pastePlainText: (() -> Void)?
    var acceptsEditorCommands: (() -> Bool)?
    private func handle(_ event: NSEvent) -> Bool {
        guard acceptsEditorCommands?() == true, let focused = firstResponder as? NSView, let editor,
              focused === editor || focused.isDescendant(of: editor) else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let name: String?
        switch (flags, event.keyCode) {
        case (.command, 0): name = "selectAll"
        case (.command, 6): name = "undo"
        case ([.command, .shift], 6): name = "redo"
        case (.command, 11): name = "bold"
        case (.command, 34): name = "italic"
        case ([.command, .shift], 8): name = "code"
        case ([.command, .shift], 9): pastePlainText?(); return true
        default: name = nil
        }
        guard let name else { return false }
        command?(name)
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event) || super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }
}
