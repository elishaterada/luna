import Foundation

enum InlineLinks {
    private static let expression = try! NSRegularExpression(pattern: #"\[((?:\\.|[^\]\\\n])+)]\((https?://[^\s)]+)\)"#)

    static func containsLink(_ source: String) -> Bool {
        var fenced = false
        return source.components(separatedBy: "\n").contains { line in
            let marker = line.trimmingCharacters(in: .whitespaces).prefix(3)
            if marker == "```" || marker == "~~~" { fenced.toggle(); return false }
            if fenced { return false }
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 2), in: line) else { return false }
            return NoteEmbeds.webURL(String(line[range])) != nil
        }
    }

    static func url(in source: String) -> URL? {
        guard let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 2), in: source) else { return nil }
        return NoteEmbeds.webURL(String(source[range]))
    }

    static func mentionURLs(in source: String) -> [URL] {
        var fenced = false
        var urls: [URL] = []
        for line in source.components(separatedBy: "\n") {
            let marker = line.trimmingCharacters(in: .whitespaces).prefix(3)
            if marker == "```" || marker == "~~~" { fenced.toggle(); continue }
            if fenced { continue }
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let labelRange = Range(match.range(at: 1), in: line),
                      String(line[labelRange]) == "Mention",
                      let urlRange = Range(match.range(at: 2), in: line),
                      let url = NoteEmbeds.webURL(String(line[urlRange])) else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    static func html(_ source: String) -> String {
        var result = ""
        var fenced = false
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let value = String(line)
            let marker = value.trimmingCharacters(in: .whitespaces).prefix(3)
            if marker == "```" || marker == "~~~" { fenced.toggle() }
            if fenced || marker == "```" || marker == "~~~" { result += NoteEmbeds.escape(value) }
            else { result += InlineFormatting.html(value) }
            if index < lines.count - 1 { result += "\n" }
        }
        return result
    }
}
