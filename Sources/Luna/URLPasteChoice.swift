import AppKit

enum URLPasteChoice: Int, CaseIterable {
    case plain, linked, mention, preview, embed
    var title: String { ["Plain Text", "Linked Text", "Mention", "Bookmark", "Embed Site"][rawValue] }
    func snippet(for url: URL) -> String {
        let value = url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        switch self {
        case .plain: return url.absoluteString
        case .linked: return "[URL](\(value))"
        case .mention: return "[Mention](\(value))"
        case .preview: return "\n[Bookmark](\(value))\n"
        case .embed: return "\n[Embed](\(value))\n"
        }
    }
    static func linkedSnippet(for value: String) -> String? {
        guard let url = NoteEmbeds.webURL(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? NoteEmbeds.iframeURL(value) else { return nil }
        return linked.snippet(for: url)
    }
}
