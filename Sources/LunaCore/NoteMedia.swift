import Foundation
import UniformTypeIdentifiers

public struct NoteAttachment: Codable, Sendable, Equatable {
    public let id: UUID
    public let filename: String
    public let mediaType: String
    public var reference: String { "luna-media://attachment/\(id.uuidString)" }
}

extension RecoveryStore {
    public func attachmentDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("Attachments", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    public func attachmentURL(_ attachment: NoteAttachment, noteID: UUID) -> URL {
        attachmentDirectory(noteID).appendingPathComponent(attachment.id.uuidString)
    }
    public func importMedia(_ urls: [URL], noteID: UUID) throws -> [NoteAttachment] {
        let root = attachmentDirectory(noteID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var imported: [NoteAttachment] = []
        do {
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) || type.conforms(to: .audio) || type.conforms(to: .movie) else {
                    throw NSError(domain: "Luna", code: 3, userInfo: [NSLocalizedDescriptionKey: "Choose image, audio, or video files to add to a note."])
                }
                let attachment = NoteAttachment(id: UUID(), filename: url.lastPathComponent,
                                                mediaType: type.preferredMIMEType ?? "application/octet-stream")
                let destination = attachmentURL(attachment, noteID: noteID)
                imported.append(attachment)
                try FileManager.default.copyItem(at: url, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            return imported
        } catch {
            for item in imported { try? FileManager.default.removeItem(at: attachmentURL(item, noteID: noteID)) }
            throw error
        }
    }
    public func copyAttachments(from source: Note, to destination: Note) throws {
        guard !source.media.isEmpty else { return }
        let root = attachmentDirectory(destination.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for attachment in source.media {
                try FileManager.default.copyItem(at: attachmentURL(attachment, noteID: source.id),
                                                to: attachmentURL(attachment, noteID: destination.id))
            }
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
}

extension RecoveryStore {
    /// Export portable Markdown with media in a sibling folder; the recovery note keeps its private references.
    public func export(_ note: Note, to url: URL) throws {
        var exported = note
        let folderName = url.lastPathComponent + ".assets"
        let folder = url.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        for item in note.media where note.text.contains(item.reference) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = (item.filename as NSString).pathExtension
            let filename = item.id.uuidString + (ext.isEmpty ? "" : "." + ext)
            let destination = folder.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: attachmentURL(item, noteID: note.id), to: destination)
            }
            let reference = (folderName + "/" + filename).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()")))!
            exported.text = exported.text.replacingOccurrences(of: item.reference, with: reference)
        }
        try TextFile.write(exported, to: url)
    }
    public func recoverExportedMedia(_ note: Note, from url: URL) throws -> Note {
        var result = note
        let pattern = #"!\[[^\]]*\]\(([^\s)]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        var references: [String: NoteAttachment] = [:]
        do {
            for match in regex.matches(in: note.text, range: NSRange(note.text.startIndex..., in: note.text)) {
                guard let range = Range(match.range(at: 1), in: note.text) else { continue }
                let encoded = String(note.text[range])
                guard references[encoded] == nil, let path = encoded.removingPercentEncoding,
                      path.hasPrefix(url.lastPathComponent + ".assets/"),
                      !path.split(separator: "/").contains("..") else { continue }
                let source = url.deletingLastPathComponent().appendingPathComponent(path)
                if let item = try importMedia([source], noteID: note.id).first { references[encoded] = item }
            }
        } catch {
            try? FileManager.default.removeItem(at: attachmentDirectory(note.id))
            throw error
        }
        result.attachments = Array(references.values)
        for (reference, item) in references { result.text = result.text.replacingOccurrences(of: "](\(reference))", with: "](\(item.reference))") }
        return result
    }
}
