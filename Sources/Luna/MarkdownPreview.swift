import AppKit
import JavaScriptCore
import WebKit

/// Markdown is compiled locally; only Luna’s checkbox bridge executes in the preview.
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
        // Recognize shorthand task rows at block boundaries, including inside lists.
        // Tokenizing here keeps fenced/indented code and inline code untouched.
        marked.use({extensions: [{
            name: 'taskRows', level: 'block',
            start(source) { return source.match(/^ {0,3}\[(?: |x|X)?\][ \t]+(?=\S)/m)?.index; },
            tokenizer(source) {
                const match = source.match(/^(?: {0,3}\[(?: |x|X)?\][ \t]+[^\n]+(?:\n|$))+/);
                if (!match) return;
                const items = match[0].trimEnd().split('\n').map(line => {
                    const row = line.match(/^ {0,3}\[( |x|X)?\][ \t]+(.*)$/);
                    return {checked: /x/i.test(row[1] || ''), tokens: this.lexer.inlineTokens(row[2])};
                });
                return {type: 'taskRows', raw: match[0], items};
            },
            renderer(token) {
                return '<ul class="task-list">' + token.items.map(item =>
                    '<li><input disabled="" type="checkbox"' + (item.checked ? ' checked=""' : '') +
                    '> ' + this.parser.parseInline(item.tokens) + '</li>').join('') + '</ul>\n';
            }
        }], walkTokens(token) {
            // Marked also detects standard task markers on list items. The custom
            // block already renders that checkbox, so avoid rendering it twice.
            if (token.type === 'list_item' && token.tokens?.[0]?.type === 'checkbox' &&
                token.tokens?.[1]?.type === 'taskRows') token.tokens.shift();
        }, renderer: {
            html: token => escapeHTML(token.text),
            image: token => '<span>' + escapeHTML(token.text || 'Image') + '</span>'
        }});
        // Normalize only block-level editor bullets, keeping UTF-16 offsets stable
        // for interactive task markers. Saved note text is never rewritten.
        function editorBullets(source) {
            let fence = null;
            let listIndent = null;
            return source.split('\n').map(line => {
                const row = line.match(/^([ \t]*)(.*)$/);
                const indent = row[1].replace(/\t/g, '    ').length;
                const text = row[2];
                if (fence) {
                    const closing = text.match(/^(`{3,}|~{3,})[ \t]*$/);
                    if (closing && closing[1][0] === fence[0] && closing[1].length >= fence.length) fence = null;
                    return line;
                }
                const opening = text.match(/^(?:[-+*•] +|\d+[.)] +)?(`{3,}|~{3,})(.*)$/);
                if (opening && (indent < 4 || listIndent !== null) &&
                    !(opening[1][0] === '`' && opening[2].includes('`'))) {
                    fence = opening[1]; return line;
                }
                if (!text) return line;
                if (listIndent !== null && indent < listIndent) listIndent = null;
                const marker = text.match(/^(?:[-+*•]|\d+[.)]) +/);
                if (marker && (indent < 4 || (listIndent !== null && indent <= listIndent + 4))) {
                    listIndent = indent;
                    return text.startsWith('• ') ? row[1] + '-' + text.slice(1) : line;
                }
                if (indent < 4) listIndent = null;
                return line;
            }).join('\n');
        }
        function renderMarkdown(source) {
            // Carry original UTF-16 source positions through parsing. Only markers
            // immediately following a rendered checkbox become interactive controls.
            const prefix = 'LUNATASK' + Math.random().toString(36).slice(2) + 'Z';
            const ranges = [];
            const tagged = source.replace(/^(?:[ \t]*>[ \t]*)*[ \t]*(?:(?:[-+*]|\d+[.)])[ \t]+)?(\[(?: |x|X)?\])(?=[ \t]+\S)/gm,
                (whole, marker, offset) => {
                    const start = offset + whole.length - marker.length;
                    const id = ranges.push({start, length: marker.length}) - 1;
                    return whole + ' ' + prefix + id + 'END';
                });
            let html = marked.parse(editorBullets(tagged), {gfm: true});
            html = html.replace(new RegExp('(<input[^>]*type="checkbox"[^>]*>)(\\s*)' + prefix + '(\\d+)END', 'g'),
                (_, input, space, id) => input.replace(' disabled=""', '').replace('>',
                    ' data-task-start="' + ranges[id].start + '" data-task-length="' + ranges[id].length + '" aria-label="Mark task complete or incomplete">'));
            return html.replace(new RegExp(' ' + prefix + '\\d+END', 'g'), '');
        }
        """#)
        guard let result = context.objectForKeyedSubscript("renderMarkdown")?.call(withArguments: [source]),
              context.exception == nil, let html = result.toString() else { throw RenderError.unavailable }
        return html
    }

    static func page(body: String, fontSize: CGFloat, dark: Bool, pageID: String = UUID().uuidString) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(pageID)'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
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
        .task-list { list-style: none; padding-left: 0; }
        li:has(> .task-list) { list-style: none; }
        li > .task-list { margin-bottom: 0; }
        input[type=checkbox] { margin: 0 .45em 0 0; vertical-align: middle; }
        input { accent-color: \(dark ? "#19f9d8" : "#00796b"); }
        ::selection { background: \(dark ? "#19f9d838" : "#00796b30"); }
        </style></head><body><article>\(body)</article>
        <script nonce="\(pageID)">
        document.addEventListener('change', event => {
            const box = event.target;
            if (!box.matches('input[data-task-start]')) return;
            window.webkit.messageHandlers.taskToggle.postMessage({page: '\(pageID)', start: Number(box.dataset.taskStart), length: Number(box.dataset.taskLength), checked: box.checked});
        });
        </script></body></html>
        """
    }
    enum RenderError: Error { case unavailable }
}

private final class TaskToggleHandler: NSObject, WKScriptMessageHandler {
    weak var preview: MarkdownPreview?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let page = body["page"] as? String, let start = body["start"] as? Int,
              let length = body["length"] as? Int, let checked = body["checked"] as? Bool else { return }
        preview?.toggleTask(page: page, start: start, length: length, checked: checked)
    }
}

final class MarkdownPreview: FileDropWebView, WKNavigationDelegate {
    var onTaskToggle: ((String, NSRange, String) -> Bool)?
    private var taskEdits: [Int: Int] = [:]
    private let renderQueue = DispatchQueue(label: "dev.luna.markdown", qos: .userInitiated)
    private var revision = UUID()
    private var lastSource: String?
    private var lastSize: CGFloat = 0
    private var lastDark = false

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let handler = TaskToggleHandler()
        configuration.userContentController.add(handler, name: "taskToggle")
        super.init(frame: .zero, configuration: configuration)
        handler.preview = self
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
        taskEdits = [:]
        loadHTMLString(MarkdownRenderer.page(body: "<p>Rendering preview…</p>", fontSize: fontSize, dark: dark), baseURL: nil)
        renderQueue.async { [weak self] in
            let body: String
            if source.utf8.count > 2_000_000 {
                body = "<p>This document is too large to preview. Choose Edit to read the source.</p>"
            } else {
                do { body = source.isEmpty ? "<p>Nothing to preview yet. Choose Edit to start writing.</p>" : try MarkdownRenderer.body(source) }
                catch { body = "<p>Preview could not be rendered. Choose Edit to return to the source.</p>" }
            }
            let page = MarkdownRenderer.page(body: body, fontSize: fontSize, dark: dark, pageID: request.uuidString)
            DispatchQueue.main.async {
                guard let self, self.revision == request else { return }
                self.loadHTMLString(page, baseURL: nil)
            }
        }
    }

    @discardableResult func toggleTask(page: String, start: Int, length: Int, checked: Bool) -> Bool {
        guard page == revision.uuidString, let source = lastSource, start >= 0, [2, 3].contains(length) else { return false }
        let offset = taskEdits.filter { $0.key < start }.values.reduce(0, +)
        let range = NSRange(location: start + offset, length: length + (taskEdits[start] ?? 0))
        guard range.location >= 0, NSMaxRange(range) <= (source as NSString).length,
              ["[]", "[ ]", "[x]", "[X]"].contains((source as NSString).substring(with: range)) else { return false }
        let replacement = checked ? "[x]" : "[ ]"
        lastSource = (source as NSString).replacingCharacters(in: range, with: replacement)
        guard onTaskToggle?(source, range, replacement) == true else { lastSource = source; return false }
        taskEdits[start] = replacement.utf16.count - length
        return true
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
