import AppKit

final class EditorView: NSTextView {
    var formatsLists = true
    private var dismissedCalculation: String?
    var exchangeRates = ExchangeRates.shared
    private var currencyTask: Task<Void, Never>?
    private var currencyPair: String?
    private var currencyLoading = false
    private var currencyHint: String?
    func currencyPreferencesChanged() {
        resetCurrencySuggestion()
        if !EditorPreferences.currencyConversionEnabled { exchangeRates.cancelPendingRequests() }
        needsDisplay = true
    }
    private func resetCurrencySuggestion() {
        currencyTask?.cancel()
        currencyTask = nil; currencyPair = nil; currencyLoading = false; currencyHint = nil
        toolTip = nil
    }
    private func currencyResult(_ conversion: CurrencyConversion) -> String? {
        guard EditorPreferences.currencyConversionEnabled else {
            resetCurrencySuggestion()
            currencyHint = "Enable currency conversion in Settings → Editor"
            toolTip = "Currency conversion is off. Enabling it sends currency codes to Frankfurter, an external service."
            return nil
        }
        if conversion.base == conversion.quote { return conversion.result(rate: 1) }
        if let rate = exchangeRates.cached(conversion) {
            toolTip = "Approximate reference rate · \(rate.date) · Frankfurter"
            return conversion.result(rate: rate.rate)
        }
        if currencyPair != conversion.pair {
            currencyTask?.cancel()
            currencyPair = conversion.pair; currencyLoading = true
            let rates = exchangeRates
            currencyTask = Task { [weak self] in
                // Wait for typing to settle; shared lookups coalesce across editor windows.
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard EditorPreferences.currencyConversionEnabled else { return }
                _ = await rates.rate(for: conversion)
                guard !Task.isCancelled, let self else { return }
                self.currencyLoading = false
                self.needsDisplay = true
            }
        }
        currencyHint = currencyLoading ? "Fetching exchange rate…" : "Exchange rate unavailable"
        toolTip = currencyHint
        return nil
    }
    var calculationSuggestion: String? {
        currencyHint = nil
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0 else { return nil }
        let source = string as NSString
        guard selection.location <= source.length else { return nil }
        // Bound the scan even for very large notes and lines.
        let start = max(0, selection.location - 1025)
        let before = source.substring(with: NSRange(location: start, length: selection.location - start))
        let line = before.components(separatedBy: .newlines).last ?? ""
        guard line.trimmingCharacters(in: .whitespaces).hasSuffix("="), line != dismissedCalculation,
              selection.location == source.length || CharacterSet.newlines.contains(UnicodeScalar(source.character(at: selection.location)) ?? " ") else { return nil }
        if let conversion = CurrencyConversion.parse(line) {
            guard let result = currencyResult(conversion) else { return nil }
            return (line.last?.isWhitespace == true ? "" : " ") + result
        }
        let lineStart = selection.location - (line as NSString).length
        let contextStart = max(0, lineStart - 32_768)
        var context = source.substring(with: NSRange(location: contextStart, length: lineStart - contextStart))
        if contextStart > 0 {
            context = context.firstIndex(of: "\n").map { String(context[context.index(after: $0)...]) } ?? ""
        }
        guard let result = CalculationSuggestion.result(for: line, context: context) else { return nil }
        return (line.last?.isWhitespace == true ? "" : " ") + result
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        resetCurrencySuggestion()
        dismissedCalculation = nil
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        if calculationSuggestion != nil || currencyHint != nil {
            let source = string as NSString
            let location = selectedRange().location
            let start = max(0, location - 1025)
            dismissedCalculation = source.substring(with: NSRange(location: start, length: location - start)).components(separatedBy: .newlines).last
            resetCurrencySuggestion()
            needsDisplay = true
        } else { super.cancelOperation(sender) }
    }
    var onFileDrop: (([URL]) -> Void)?
    var onEmbedPaste: ((String) -> Void)?
    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string),
           let choice = URLPasteChoice.choose(value) {
            if let snippet = choice.snippet {
                if choice.live, let onEmbedPaste { onEmbedPaste(snippet) }
                else { insertText(snippet, replacementRange: selectedRange()) }
            }
            return
        }
        super.paste(sender)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard formatsLists, let value = insertString as? String else {
            super.insertText(insertString, replacementRange: replacementRange); return
        }
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let source = string as NSString
        guard NSMaxRange(range) <= source.length else { return }
        let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
        guard range.location - lineStart <= 32_768 else { super.insertText(value, replacementRange: range); return }
        let prefix = source.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        // Never reinterpret code inside fenced blocks.
        let before = source.substring(with: NSRange(location: max(0, lineStart - 32_768), length: min(lineStart, 32_768)))
        let fenced = before.components(separatedBy: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("```") || line.hasPrefix("~~~")
        }.count % 2 == 1
        let formatted = fenced ? prefix + value : NoteLists.formatted(prefix + value)
        if formatted != prefix + value {
            super.insertText(formatted, replacementRange: NSRange(location: lineStart, length: NSMaxRange(range) - lineStart))
        } else { super.insertText(value, replacementRange: range) }
    }
    override func mouseDown(with event: NSEvent) {
        if formatsLists {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let ns = string as NSString
            if index < ns.length {
                let line = ns.lineRange(for: NSRange(location: index, length: 0))
                let prefix = ns.substring(with: NSRange(location: line.location, length: index - line.location))
                let marker = ns.substring(with: NSRange(location: index, length: 1))
                if prefix.trimmingCharacters(in: .whitespaces).isEmpty, ["☐", "☑"].contains(marker) {
                    insertText(marker == "☐" ? "☑" : "☐", replacementRange: NSRange(location: index, length: 1)); return
                }
            }
        }
        super.mouseDown(with: event)
    }
    private func files(_ sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let files = files(sender), !files.isEmpty, onFileDrop != nil { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let files = files(sender), !files.isEmpty, onFileDrop != nil { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let files = files(sender), !files.isEmpty, onFileDrop != nil { return true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let files = files(sender), !files.isEmpty, let onFileDrop else { return super.performDragOperation(sender) }
        onFileDrop(files); return true
    }

    override var string: String { didSet { resetCurrencySuggestion(); needsDisplay = true } }
    override func didChangeText() {
        super.didChangeText()
        dismissedCalculation = nil
        resetCurrencySuggestion()
        // TextKit redraws glyphs independently; invalidate our empty-state drawing too.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let suggestion = calculationSuggestion
        if let suggestion = suggestion ?? currencyHint.map({ " " + $0 }), let window, window.firstResponder === self {
            let caret = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
            let rect = convert(window.convertFromScreen(caret), from: nil)
            let suggestionFont = font ?? NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
            let available = NSRect(x: rect.minX, y: rect.minY, width: max(0, bounds.maxX - textContainerInset.width - rect.minX), height: rect.height)
            NSGraphicsContext.saveGraphicsState()
            available.clip()
            (suggestion as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: [
                .font: suggestionFont, .foregroundColor: Theme.muted.withAlphaComponent(0.65)
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
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
        if formatsLists, let list = NoteLists.continuation(prefix) {
            if list.empty {
                insertText("", replacementRange: NSRange(location: line.location, length: location - line.location))
            } else { insertText("\n" + list.prefix, replacementRange: selectedRange()) }
            return
        }
        super.insertNewline(sender)
        if EditorPreferences.autoIndent && !indentation.isEmpty { insertText(indentation, replacementRange: selectedRange()) }
    }
    override func insertTab(_ sender: Any?) {
        if calculationSuggestion == nil, indentList(outdent: false) { return }
        let value = calculationSuggestion ?? (EditorPreferences.useTabs ? "\t" : String(repeating: " ", count: EditorPreferences.tabWidth))
        insertText(value, replacementRange: selectedRange())
    }
    override func insertBacktab(_ sender: Any?) {
        if indentList(outdent: true) { return }
        super.insertBacktab(sender)
    }
    private func indentList(outdent: Bool) -> Bool {
        guard formatsLists, !hasMarkedText(), selectedRange().length == 0 else { return false }
        let selection = selectedRange()
        let source = string as NSString
        let lineRange = source.lineRange(for: selection)
        let line = source.substring(with: lineRange)
        let context = source.substring(with: NSRange(location: max(0, lineRange.location - 32_768), length: min(lineRange.location, 32_768)))
        let fenced = context.components(separatedBy: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }.count % 2 == 1
        guard !fenced, NoteLists.continuation(line) != nil else { return false }
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let removed = outdent ? (indent.hasPrefix("\t") ? 1 : min(indent.prefix { $0 == " " }.count, EditorPreferences.tabWidth)) : 0
        let added = outdent ? "" : (EditorPreferences.useTabs ? "\t" : String(repeating: " ", count: EditorPreferences.tabWidth))
        if removed == 0 && added.isEmpty { return true }
        insertText(added, replacementRange: NSRange(location: lineRange.location, length: removed))
        setSelectedRange(NSRange(location: max(lineRange.location, selection.location - removed + (added as NSString).length), length: 0))
        return true
    }

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
        if let editor = view as? EditorView, editor.formatsLists {
            let fullLines = (view.string as NSString).lineRange(for: range)
            let lines = NSRange(location: fullLines.location, length: min(fullLines.length, 32_768))
            let snippet = (view.string as NSString).substring(with: lines)
            var offset = lines.location
            for line in snippet.components(separatedBy: "\n") {
                let length = (line as NSString).length
                if length > 0 {
                    let paragraph = (view.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    paragraph.lineSpacing = (view.font?.pointSize ?? 18) * EditorPreferences.lineSpacing
                    if NoteLists.continuation(line) != nil {
                        let marker = line.range(of: NoteLists.pattern, options: .regularExpression).map { String(line[$0]) } ?? ""
                        paragraph.headIndent = (marker as NSString).size(withAttributes: [.font: view.font ?? NSFont.systemFont(ofSize: 18)]).width
                    }
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: offset, length: length))
                }
                offset += length + 1
            }
        }
        storage.endEditing()
    }
}
