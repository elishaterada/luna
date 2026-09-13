import AppKit

final class EditorView: NSTextView {
    override var string: String { didSet { needsDisplay = true } }
    override func didChangeText() {
        super.didChangeText()
        // TextKit redraws glyphs independently; invalidate our empty-state drawing too.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
        ("Start with a thought." as NSString).draw(at: origin, withAttributes: [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
            .foregroundColor: Theme.muted
        ])
    }

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let location = selectedRange().location
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: location - line.location))
        let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if EditorPreferences.autoIndent && !indentation.isEmpty { insertText(indentation, replacementRange: selectedRange()) }
    }
    override func insertTab(_ sender: Any?) { insertText(EditorPreferences.useTabs ? "\t" : String(repeating: " ", count: EditorPreferences.tabWidth), replacementRange: selectedRange()) }
}

/// Color only the visible viewport plus context. No access to layoutManager:
/// that accessor would silently replace TextKit 2 with the legacy engine.
final class SyntaxHighlighter {
    private var rules: [(NSRegularExpression, NSColor)] = []
    private var language = ""
    func configure(_ language: String) {
        guard self.language != language else { return }
        self.language = language; rules = []
        guard language != "Plain Text" else { return }
        func rule(_ pattern: String, _ color: NSColor) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) { rules.append((regex, color)) }
        }
        rule(#"\b\d+(?:\.\d+)?\b"#, Theme.peach)
        rule(#"\b(?:true|false|null|nil|None|True|False|undefined)\b"#, Theme.peach)
        rule(#"\b(?:const|let|var|function|return|if|else|for|while|switch|case|break|class|struct|enum|import|from|export|default|async|await|try|catch|throw|new|def|in|print|func|guard|public|private|echo|then|fi|do|done|extends)\b"#, Theme.pink)
        rule(#"\b[A-Za-z_$][\w$]*(?=\s*\()"#, Theme.blue)
        if ["YAML", "JSON", "Environment", "Configuration", "Shell"].contains(language) {
            rule(#"^\s*[\w.\-]+(?=\s*[:=])"#, Theme.mint)
            rule(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, Theme.blue)
        }
        rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`\n]*`"#, Theme.mint)
        if ["Shell", "Python", "YAML", "Environment", "Configuration"].contains(language) {
            rule(#"(?:^|\s)#.*$"#, Theme.muted)
        } else if language != "Markdown" {
            rule(#"//.*$|/\*[\s\S]*?\*/"#, Theme.muted)
        }
        if language == "Markdown" {
            rules = []
            rule(#"^#{1,6}\s.+$"#, Theme.mint)
            rule(#"\*\*[^*]+\*\*|__[^_]+__"#, Theme.peach)
            rule(#"`[^`]+`"#, Theme.blue)
            rule(#"^\s*(?:[-*+]|\d+\.)\s|^>.*$"#, Theme.pink)
            rule(#"\[[^\]]+\]\([^\)]+\)"#, Theme.blue)
        }
    }
    func highlight(_ view: NSTextView) {
        guard let storage = view.textStorage, storage.length > 0,
              let manager = view.textLayoutManager,
              let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let lower = max(0, start - 2048)
        let upper = min(storage.length, max(end, start + 4096) + 2048)
        // Protect the UI from pathological megabyte-long lines and regex input.
        let range = NSRange(location: lower, length: min(upper - lower, 32_768))
        let snippet = (view.string as NSString).substring(with: range)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: Theme.text, range: range)
        for (regex, color) in (EditorPreferences.syntaxColors ? rules : []) {
            regex.enumerateMatches(in: snippet, range: NSRange(location: 0, length: (snippet as NSString).length)) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: color,
                                     range: NSRange(location: range.location + match.range.location, length: match.range.length))
            }
        }
        storage.endEditing()
    }
}
