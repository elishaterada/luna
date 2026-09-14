import AppKit

enum URLPasteChoice: Int, CaseIterable {
    case plain, linked, preview, embed
    var title: String { ["Plain Text", "Linked Text", "Preview Chip", "Embed Site"][rawValue] }
    func snippet(for url: URL) -> String {
        let value = url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        switch self {
        case .plain: return url.absoluteString
        case .linked: return "\n[\(url.host ?? "Link")](\(value))\n"
        case .preview: return "\n[Preview](\(value))\n"
        case .embed: return "\n[Embed](\(value))\n"
        }
    }
    @MainActor static func choose(_ value: String) -> (snippet: String?, live: Bool)? {
        guard let url = NoteEmbeds.webURL(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? NoteEmbeds.iframeURL(value) else { return nil }
        let alert = NSAlert()
        alert.messageText = "Paste URL as…"
        alert.informativeText = "\(url.absoluteString)\n\nSome websites do not allow embedding."
        for choice in allCases { alert.addButton(withTitle: choice.title) }
        alert.addButton(withTitle: "Cancel")
        guard let choice = Self(rawValue: alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) else { return (nil, false) }
        return (choice == .plain ? value : choice.snippet(for: url), choice != .plain)
    }
}
