import AppKit
import WebKit

/// Throwaway, memory-only editor evaluation. It receives a string copy and has no recovery bridge.
final class ProseMirrorPrototype: NSWindowController, WKNavigationDelegate {
    private let webView: WKWebView
    private let source: String
    private let fontSize: CGFloat

    init(source: String, fontSize: CGFloat) {
        self.source = source
        self.fontSize = fontSize
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = ProseMirrorPrototypeWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ProseMirror trial — Luna"
        window.minSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false
        window.appearance = EditorPreferences.nsAppearance
        window.contentView = webView
        window.center()
        window.editor = webView
        window.command = { [weak self] name in self?.command(name) }
        window.pastePlainText = { [weak self] in self?.pastePlainText() }
        webView.setAccessibilityLabel("ProseMirror trial")
        webView.navigationDelegate = self
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Luna_Luna.bundle").path
        let resources = packaged.flatMap { Bundle(path: $0) } ?? Bundle.module
        if let url = resources.url(forResource: "ProseMirrorPrototype", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

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
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }
}

/// Route native menu shortcuts to ProseMirror's history and commands in this window only.
private final class ProseMirrorPrototypeWindow: NSWindow {
    weak var editor: WKWebView?
    var command: ((String) -> Void)?
    var pastePlainText: (() -> Void)?
    private func handle(_ event: NSEvent) -> Bool {
        guard let focused = firstResponder as? NSView, let editor,
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
