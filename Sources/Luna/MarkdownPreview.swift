import AppKit
import JavaScriptCore
import WebKit

/// Markdown is compiled locally; document HTML and scripts never execute.
enum MarkdownRenderer {
    static func body(_ source: String) throws -> String {
        // SwiftPM's generated accessor does not search Contents/Resources in a shipped app.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Luna_Luna.bundle").path
        let resources = packaged.flatMap { Bundle(path: $0) } ?? Bundle.module
        guard let url = resources.url(forResource: "marked", withExtension: "js", subdirectory: "Resources"),
              let context = JSContext() else { throw RenderError.unavailable }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        context.evaluateScript(#"""
        const escapeHTML = s => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        marked.use({renderer: {
            html: token => escapeHTML(token.text),
            image: token => '<span>' + escapeHTML(token.text || 'Image') + '</span>'
        }});
        function renderMarkdown(source) { return marked.parse(source, {gfm: true}); }
        """#)
        guard let result = context.objectForKeyedSubscript("renderMarkdown")?.call(withArguments: [source]),
              context.exception == nil, let html = result.toString() else { throw RenderError.unavailable }
        return html
    }

    static func page(body: String, fontSize: CGFloat, dark: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        body { margin: 0; padding: 24px 40px 48px; color: \(dark ? "#cccccc" : "#242833");
          font: \(fontSize)px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
        article { max-width: 72ch; margin: 0 auto; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin: 1.5em 0 .5em; font-weight: 650; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.2em; }
        article > :first-child { margin-top: 0; }
        p,ul,ol,pre,blockquote,table { margin: 0 0 1em; }
        li > p { margin-bottom: .4em; } ul,ol { padding-left: 1.6em; }
        a { color: \(dark ? "#45a9f9" : "#0969ad"); text-underline-offset: .16em; }
        a:focus-visible { outline: 2px solid currentColor; outline-offset: 3px; }
        code { font: .88em/1.6 ui-monospace, Menlo, monospace; background: \(dark ? "#ffffff0c" : "#00000008"); padding: .12em .3em; border-radius: 3px; }
        pre { overflow-x: auto; padding: 16px; background: \(dark ? "#ffffff0c" : "#00000008"); border-radius: 6px; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 1px solid currentColor; padding-left: 1em; }
        table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; font-variant-numeric: tabular-nums; }
        th,td { border: 1px solid \(dark ? "#55595e" : "#b9bec7"); padding: .4em .75em; text-align: left; }
        hr { border: 0; border-top: 1px solid \(dark ? "#55595e" : "#b9bec7"); margin: 1.5em 0; }
        input { accent-color: \(dark ? "#19f9d8" : "#00796b"); }
        ::selection { background: \(dark ? "#19f9d838" : "#00796b30"); }
        </style></head><body><article>\(body)</article></body></html>
        """
    }
    enum RenderError: Error { case unavailable }
}

final class MarkdownPreview: WKWebView, WKNavigationDelegate {
    private let renderQueue = DispatchQueue(label: "dev.luna.markdown", qos: .userInitiated)
    private var revision = UUID()
    private var lastSource: String?
    private var lastSize: CGFloat = 0
    private var lastDark = false

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        setAccessibilityLabel("Markdown preview")
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ source: String, fontSize: CGFloat, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard lastSource != source || lastSize != fontSize || lastDark != dark else { return }
        lastSource = source; lastSize = fontSize; lastDark = dark
        let request = UUID(); revision = request
        loadHTMLString(MarkdownRenderer.page(body: "<p>Rendering preview…</p>", fontSize: fontSize, dark: dark), baseURL: nil)
        renderQueue.async { [weak self] in
            let body: String
            if source.utf8.count > 2_000_000 {
                body = "<p>This document is too large to preview. Choose Edit to read the source.</p>"
            } else {
                do { body = source.isEmpty ? "<p>Nothing to preview yet. Choose Edit to start writing.</p>" : try MarkdownRenderer.body(source) }
                catch { body = "<p>Preview could not be rendered. Choose Edit to return to the source.</p>" }
            }
            let page = MarkdownRenderer.page(body: body, fontSize: fontSize, dark: dark)
            DispatchQueue.main.async {
                guard let self, self.revision == request else { return }
                self.loadHTMLString(page, baseURL: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        } else {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
