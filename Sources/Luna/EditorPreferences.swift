import AppKit

/// Local preferences shared by Settings, menu commands, and the editor.
enum EditorPreferences {
    static func isTypingFeedbackEvent(characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard !isRepeat, modifiers.intersection([.command, .control]).isEmpty,
              let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            $0.value == 3 || $0.value == 13 || $0.value == 127 || ($0.value >= 32 && !($0.value >= 0xF700 && $0.value <= 0xF8FF))
        }
    }
    static let changed = Notification.Name("Luna.editorPreferencesChanged")
    static var appearance: String { UserDefaults.standard.string(forKey: "editor.appearance") ?? "dark" }
    static var fontFamily: String { UserDefaults.standard.string(forKey: "editor.fontFamily") ?? "SF Mono" }
    static var fontSize: CGFloat {
        get { let value = UserDefaults.standard.double(forKey: "editor.fontSize"); return value.isFinite && value > 0 ? min(48, max(12, value)) : 18 }
        set { UserDefaults.standard.set(newValue, forKey: "editor.fontSize"); notify() }
    }
    static var compact: Bool { UserDefaults.standard.bool(forKey: "editor.compactSpacing") }
    static var autoIndent: Bool { UserDefaults.standard.object(forKey: "editor.autoIndent") as? Bool ?? true }
    static var tabWidth: Int { let value = UserDefaults.standard.integer(forKey: "editor.tabWidth"); return [2, 4, 8].contains(value) ? value : 4 }
    static let fontFamilies: [String] = {
        let installed = NSFontManager.shared.availableFontFamilies.filter {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 14)?.isFixedPitch == true
        }
        return Array(Set(installed + ["SF Mono"])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()
    static func font(at size: CGFloat, family: String? = nil) -> NSFont {
        NSFontManager.shared.font(withFamily: family ?? fontFamily, traits: [], weight: 5, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    static var isLight: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua }
    static var lineSpacing: CGFloat { bounded("editor.lineSpacing", default: 0.3, range: 0...1) }
    static var editorPadding: CGFloat { bounded("editor.padding", default: 40, range: 16...80) }
    static var presentationSize: CGFloat { bounded("editor.presentationSize", default: 26, range: 20...60) }
    static var wrapLines: Bool { UserDefaults.standard.object(forKey: "editor.wrapLines") as? Bool ?? true }
    static var syntaxColors: Bool { UserDefaults.standard.object(forKey: "editor.syntaxColors") as? Bool ?? true }
    static var spellChecking: Bool { UserDefaults.standard.bool(forKey: "editor.spellChecking") }
    static var useTabs: Bool { UserDefaults.standard.bool(forKey: "editor.useTabs") }
    private static func bounded(_ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = UserDefaults.standard.object(forKey: key) as? Double, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    static var nsAppearance: NSAppearance? {
        switch appearance { case "light": return NSAppearance(named: .aqua); case "dark": return NSAppearance(named: .darkAqua); default: return nil }
    }
    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }
    static func resetAppearance() {
        for key in ["editor.appearance", "editor.fontFamily", "editor.fontSize", "editor.compactSpacing", "editor.lineSpacing", "editor.padding"] { UserDefaults.standard.removeObject(forKey: key) }
        notify()
    }
}
