import AppKit

/// Visible list markers remain portable when a note is saved as plain text.
enum NoteLists {
    static let pattern = #"^(\s*)(?:([-*+•]) |(\d+)[.)] |([☐☑]) )"#
    static func formatted(_ text: String) -> String {
        var fence: String?
        return text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                return line
            }
            guard fence == nil else { return line }
            return line.replacingOccurrences(of: #"^([ \t]*)(?:[-*+•] )?\[[xX]\] "#, with: "$1☑ ", options: .regularExpression)
                .replacingOccurrences(of: #"^([ \t]*)(?:[-*+•] )?\[ \] "#, with: "$1☐ ", options: .regularExpression)
                .replacingOccurrences(of: #"^([ \t]*)[-*+] "#, with: "$1• ", options: .regularExpression)
                .replacingOccurrences(of: #"^([ \t]*)(\d+)\) "#, with: "$1$2. ", options: .regularExpression)
        }.joined(separator: "\n")
    }
    static func continuation(_ line: String) -> (prefix: String, empty: Bool)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let ns = line as NSString
        let indent = ns.substring(with: match.range(at: 1))
        let marker: String
        if match.range(at: 3).location != NSNotFound {
            guard let number = Int(ns.substring(with: match.range(at: 3))), number < Int.max else { return nil }
            marker = "\(number + 1). "
        } else if match.range(at: 4).location != NSNotFound { marker = "☐ " }
        else { marker = "• " }
        return (indent + marker, ns.substring(from: match.range.length).trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
