import Foundation

/// Only URLs are taken from embed HTML. Provider scripts and attributes never enter the note page.
enum NoteEmbeds {
    enum Block: Equatable {
        case text(String)
        case media(source: String, id: UUID)
        case link(source: String, url: URL, label: String, preview: Bool)
        case embed(source: String, url: URL)
        var source: String {
            switch self { case .text(let value), .media(let value, _), .embed(let value, _), .link(let value, _, _, _): return value }
        }
    }
    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              !value.contains(where: { $0.isWhitespace }),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func attribute(_ name: String, in html: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: html) {
                return String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            }
        }
        return nil
    }
    static func iframeURL(_ html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"<iframe\b[^>]*>"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html), let src = attribute("src", in: String(html[range])) else { return nil }
        return webURL(src)
    }
    static func insertion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = iframeURL(trimmed) { return "\n[Embed](\(url.absoluteString))\n" }
        if let url = webURL(trimmed) { return "\n[Embed](\(url.absoluteString))\n" }
        return nil
    }
    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var text: [String] = []
        var fence: String?
        func flush() { if !text.isEmpty { blocks.append(.text(text.joined(separator: "\n"))); text = [] } }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                text.append(line); continue
            }
            guard fence == nil else { text.append(line); continue }
            if let regex = try? NSRegularExpression(pattern: #"^!\[[^\]]*\]\(luna-media://attachment/([A-Fa-f0-9-]+)\)$"#),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed), let id = UUID(uuidString: String(trimmed[range])) {
                flush(); blocks.append(.media(source: line, id: id)); continue
            }
            var candidate = trimmed
            if trimmed.hasPrefix("[Embed]("), trimmed.hasSuffix(")") { candidate = String(trimmed.dropFirst(8).dropLast()) }
            if let regex = try? NSRegularExpression(pattern: #"^\[([^\]]+)\]\((https?://[^\s]+)\)$"#),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let labelRange = Range(match.range(at: 1), in: trimmed),
               let urlRange = Range(match.range(at: 2), in: trimmed),
               String(trimmed[labelRange]) != "Embed", let url = webURL(String(trimmed[urlRange])) {
                let label = String(trimmed[labelRange])
                flush(); blocks.append(.link(source: line, url: url, label: label, preview: label == "Preview")); continue
            }
            if let url = (trimmed.hasPrefix("[Embed](") ? webURL(candidate) : nil) ?? iframeURL(trimmed) {
                flush(); blocks.append(.embed(source: line, url: url)); continue
            }
            text.append(line)
        }
        flush()
        return blocks
    }
    static func hasContent(_ source: String) -> Bool {
        guard source.utf8.count <= 2_000_000 else { return false }
        return blocks(source).contains { if case .text = $0 { return false }; return true }
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

actor EmbedResolver {
    static let shared = EmbedResolver()
    private var cache: [URL: URL] = [:]
    private let session = URLSession(configuration: .ephemeral)

    func resolve(_ url: URL) async -> URL {
        if let cached = cache[url] { return cached }
        let resolved = await discover(url) ?? url
        cache[url] = resolved
        return resolved
    }
    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              data.count < 2_000_000, response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        return (data, response)
    }
    private func discover(_ url: URL) async -> URL? {
        do {
            let host = url.host?.lowercased() ?? ""
            let endpoint: String?
            switch host {
            case "youtube.com", "www.youtube.com", "youtu.be": endpoint = "https://www.youtube.com/oembed"
            case "vimeo.com", "www.vimeo.com": endpoint = "https://vimeo.com/api/oembed.json"
            case "open.spotify.com": endpoint = "https://open.spotify.com/oembed"
            case "soundcloud.com", "www.soundcloud.com": endpoint = "https://soundcloud.com/oembed"
            default: endpoint = nil
            }
            if let endpoint, var components = URLComponents(string: endpoint) {
                components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
                if let request = components.url, let result = try? await fetch(request), let resolved = Self.responseURL(result.0) { return resolved }
            }
            let (data, response) = try await fetch(url)
            if let result = Self.responseURL(data) { return result }
            guard let html = String(data: data, encoding: .utf8),
                  let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return nil }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                let tag = String(html[range])
                guard NoteEmbeds.attribute("type", in: tag)?.lowercased() == "application/json+oembed",
                      let href = NoteEmbeds.attribute("href", in: tag),
                      let endpoint = URL(string: href, relativeTo: response.url)?.absoluteURL,
                      NoteEmbeds.webURL(endpoint.absoluteString) != nil else { continue }
                return Self.responseURL(try await fetch(endpoint).0)
            }
            // Some providers advertise discovery through HTTP Link headers.
            if let link = response.value(forHTTPHeaderField: "Link"), link.contains("application/json+oembed"),
               let start = link.firstIndex(of: "<"), let end = link[start...].firstIndex(of: ">"),
               let endpoint = NoteEmbeds.webURL(String(link[link.index(after: start)..<end])) {
                return Self.responseURL(try await fetch(endpoint).0)
            }
        } catch { }
        return nil
    }
    static func responseURL(_ data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["type"] as? String == "photo", let value = object["url"] as? String { return NoteEmbeds.webURL(value) }
        if let html = object["html"] as? String { return NoteEmbeds.iframeURL(html) }
        return nil
    }
}
