import Foundation

actor LinkMetadata {
    struct Details: Equatable {
        let title: String?
        let description: String?
        let favicon: URL?
        let image: URL?
    }
    static let shared = LinkMetadata()
    private let session = URLSession(configuration: .ephemeral)
    private var cache: [URL: Details] = [:]

    func title(for url: URL) async -> String? {
        await details(for: url).title
    }

    func details(for url: URL) async -> Details {
        if let details = cache[url] { return details }
        let fallback = Details(title: nil, description: nil, favicon: Self.faviconFallback(for: url), image: nil)
        guard NoteEmbeds.webURL(url.absoluteString) != nil else { return fallback }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.setValue("Twitterbot", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  let finalURL = response.url, NoteEmbeds.webURL(finalURL.absoluteString) != nil,
                  ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else { return fallback }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                if data.count >= 512_000 { break }
                if byte == 62, data.count >= 7, String(decoding: data.suffix(7), as: UTF8.self).lowercased() == "</head>" { break }
            }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let parsed = Self.parseDetails(html, baseURL: finalURL)
            let details = Details(title: parsed.title, description: parsed.description,
                                  favicon: parsed.favicon ?? Self.faviconFallback(for: finalURL), image: parsed.image)
            cache[url] = details
            return details
        } catch { }
        return fallback
    }

    static func parseTitle(_ html: String) -> String? {
        parseDetails(html, baseURL: nil).title
    }

    static func parseDetails(_ html: String, baseURL: URL?) -> Details {
        // Prefer social metadata, then the document title. Never execute page scripts.
        let html = html.replacingOccurrences(of: #"<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?</script\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        var metadata: [String: String] = [:]
        if let regex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                let tag = String(html[range])
                if let key = NoteEmbeds.attribute("property", in: tag) ?? NoteEmbeds.attribute("name", in: tag),
                   let value = NoteEmbeds.attribute("content", in: tag) { metadata[key.lowercased()] = value }
            }
        }
        var candidates = [metadata["og:title"], metadata["twitter:title"]].compactMap { $0 }
        if let regex = try? NSRegularExpression(pattern: #"<title\b[^>]*>([\s\S]*?)</title\s*>"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) { candidates.append(String(html[range])) }
        let title = candidates.compactMap { clean($0, maxLength: 300) }.first
        let description = [metadata["og:description"], metadata["twitter:description"], metadata["description"]]
            .compactMap { $0.flatMap { clean($0, maxLength: 500) } }.first
        let image = baseURL.flatMap { baseURL in
            [metadata["og:image:secure_url"], metadata["og:image"], metadata["og:image:url"],
             metadata["twitter:image"], metadata["twitter:image:src"]]
                .compactMap { value -> URL? in
                    guard let value, let candidate = URL(string: decodeEntities(value), relativeTo: baseURL)?.absoluteURL,
                          candidate.scheme?.lowercased() == "https", candidate.absoluteString.utf8.count < 2_048,
                          NoteEmbeds.webURL(candidate.absoluteString) != nil else { return nil }
                    return candidate
                }.first
        }
        var favicon: URL?
        if let baseURL, let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) {
            var icons: [(Int, URL)] = []
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                let tag = String(html[range])
                guard let rel = NoteEmbeds.attribute("rel", in: tag)?.lowercased(),
                      (rel.split(separator: " ").contains("icon") || rel.contains("apple-touch-icon")),
                      let href = NoteEmbeds.attribute("href", in: tag),
                      let icon = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL,
                      icon.absoluteString.utf8.count < 2_048,
                      NoteEmbeds.webURL(icon.absoluteString) != nil else { continue }
                icons.append((rel.contains("apple-touch") ? 1 : 0, icon))
            }
            favicon = icons.min { $0.0 < $1.0 }?.1
        }
        return Details(title: title, description: description, favicon: favicon, image: image)
    }

    private static func faviconFallback(for url: URL) -> URL? {
        guard let icon = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL,
              NoteEmbeds.webURL(icon.absoluteString) != nil else { return nil }
        return icon
    }

    private static func clean(_ text: String, maxLength: Int) -> String? {
        let value = decodeEntities(text).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(maxLength))
    }
    private static func decodeEntities(_ text: String) -> String {
        let entities = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©"]
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);"#) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange])
            let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : (key.hasPrefix("#") ? UInt32(key.dropFirst()) : nil)
            let value = number.flatMap(UnicodeScalar.init).map(String.init) ?? entities[key]
            if let value { result.replaceSubrange(range, with: value) }
        }
        return result
    }
}
