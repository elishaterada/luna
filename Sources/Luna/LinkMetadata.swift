import Foundation

actor LinkMetadata {
    static let shared = LinkMetadata()
    private let session = URLSession(configuration: .ephemeral)
    private var cache: [URL: String] = [:]

    func title(for url: URL) async -> String? {
        if let title = cache[url] { return title }
        guard NoteEmbeds.webURL(url.absoluteString) != nil else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  let finalURL = response.url, NoteEmbeds.webURL(finalURL.absoluteString) != nil,
                  ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else { return nil }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                if data.count >= 512_000 { break }
                if byte == 62, data.count >= 7, String(decoding: data.suffix(7), as: UTF8.self).lowercased() == "</head>" { break }
            }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            if let title = Self.parseTitle(html) { cache[url] = title; return title }
        } catch { }
        return nil
    }

    static func parseTitle(_ html: String) -> String? {
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
        for candidate in candidates {
            let title = decodeEntities(candidate).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return String(title.prefix(300)) }
        }
        return nil
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
