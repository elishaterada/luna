import Foundation

public struct Note: Codable, Identifiable, Sendable {
    public var attachments: [NoteAttachment]?
    public var media: [NoteAttachment] { attachments ?? [] }
    private var pinned: Bool?
    public var isPinned: Bool {
        get { pinned ?? false }
        set { pinned = newValue }
    }
    public var id: UUID
    public var text: String
    public var path: String?
    public var language: String
    public var modified: Date
    public var diskModified: Date?
    public var dirty: Bool
    public var encoding: UInt
    public init(text: String = "", path: String? = nil, language: String = "Plain Text") {
        id = UUID(); self.text = text; self.path = path; self.language = language
        modified = Date(); dirty = false; encoding = String.Encoding.utf8.rawValue
    }
    public var title: String {
        if let path { return URL(fileURLWithPath: path).lastPathComponent }
        let firstLine = text.drop(while: \.isNewline).prefix(48).prefix { !$0.isNewline }
        return firstLine.isEmpty ? "Untitled note" : String(firstLine)
    }
    public static func language(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") { return "Environment" }
        if [".zshrc", ".bashrc", ".bash_profile", ".zprofile"].contains(name) { return "Shell" }
        switch url.pathExtension.lowercased() {
        case "js", "jsx", "mjs", "cjs": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "yml", "yaml": return "YAML"
        case "md", "markdown": return "Markdown"
        case "json", "jsonc": return "JSON"
        case "sh", "zsh", "bash": return "Shell"
        case "py": return "Python"
        case "swift": return "Swift"
        case "css": return "CSS"
        case "html", "xml", "svg": return "HTML"
        case "toml", "ini", "conf": return "Configuration"
        default: return "Plain Text"
        }
    }
}

/// Each note is an independent atomic recovery record. File-backed edits are
/// recovered here too; writing the original always requires Save.
public final class RecoveryStore: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public func save(_ note: Note) throws {
        let data = try JSONEncoder().encode(note)
        let url = directory.appendingPathComponent(note.id.uuidString).appendingPathExtension("json")
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public private(set) var unreadableFiles: [URL] = []
    public func load() throws -> [Note] {
        unreadableFiles = []
        let notes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                do { return try JSONDecoder().decode(Note.self, from: Data(contentsOf: url)) }
                catch { unreadableFiles.append(url); return nil }
            }
            .sorted { $0.modified > $1.modified }
        let orderURL = directory.appendingPathComponent("sidebar-order.plist")
        let order = (try? PropertyListDecoder().decode([UUID].self, from: Data(contentsOf: orderURL))) ?? []
        var remaining = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        let ordered = order.compactMap { remaining.removeValue(forKey: $0) }
        return notes.filter { remaining[$0.id] != nil } + ordered
    }
    public func saveOrder(_ ids: [UUID]) throws {
        let url = directory.appendingPathComponent("sidebar-order.plist")
        try PropertyListEncoder().encode(ids).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func remove(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
        let assets = attachmentDirectory(id)
        if FileManager.default.fileExists(atPath: assets.path) { try FileManager.default.removeItem(at: assets) }
    }
}

public enum TextFile {
    public static func read(_ url: URL) throws -> Note {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 100 * 1024 * 1024 else {
            throw NSError(domain: "Luna", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file exceeds Luna’s 100 MB safety limit."])
        }
        var encoding = String.Encoding.utf8
        let text: String
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            encoding = .utf16
            guard let value = String(data: data, encoding: encoding) else { throw invalidText() }
            text = value
        } else {
            guard !data.contains(0), let value = String(data: data, encoding: .utf8) else { throw invalidText() }
            text = value
        }
        var note = Note(text: text, path: url.path, language: Note.language(for: url))
        note.encoding = encoding.rawValue
        note.diskModified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        note.modified = note.diskModified ?? note.modified
        return note
    }
    private static func invalidText() -> NSError {
        NSError(domain: "Luna", code: 2, userInfo: [NSLocalizedDescriptionKey: "Luna opens UTF-8 and UTF-16 text. This file is binary or uses an unsupported encoding."])
    }
    public static func write(_ note: Note, to url: URL) throws {
        guard let data = note.text.data(using: String.Encoding(rawValue: note.encoding)) else { throw invalidText() }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
