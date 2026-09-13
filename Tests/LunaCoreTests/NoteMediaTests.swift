import XCTest
@testable import LunaCore

final class NoteMediaTests: XCTestCase {
    func testMediaSurvivesOriginalDeletionDuplicationExportAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let original = root.appendingPathComponent("photo.png")
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
        try data.write(to: original)
        var note = Note(text: "A photo")
        note.attachments = try store.importMedia([original], noteID: note.id)
        let attachment = try XCTUnwrap(note.media.first)
        note.text += "\n![Photo](\(attachment.reference))\n"
        try store.save(note)
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment, noteID: note.id)), data)
        XCTAssertEqual(try store.load().first?.media, note.media)
        var copy = Note(text: note.text)
        copy.attachments = note.attachments
        try store.copyAttachments(from: note, to: copy)
        try store.save(copy)
        let export = root.appendingPathComponent("My note.md")
        try store.export(note, to: export)
        let exported = try TextFile.read(export)
        XCTAssertFalse(exported.text.contains("luna-media:"))
        XCTAssertTrue(exported.text.contains("My%20note.md.assets/"))
        let reopened = try store.recoverExportedMedia(exported, from: export)
        XCTAssertEqual(reopened.media.count, 1)
        XCTAssertTrue(reopened.text.contains("luna-media:"))
        try store.remove(note.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentDirectory(note.id).path))
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(attachment, noteID: copy.id)), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
    }
    func testRejectedBatchRollsBackAndLegacyNotesStillDecode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root)
        let image = root.appendingPathComponent("photo.png")
        let text = root.appendingPathComponent("text.txt")
        try Data().write(to: image); try Data().write(to: text)
        let note = Note()
        XCTAssertThrowsError(try store.importMedia([image, text], noteID: note.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.attachmentDirectory(note.id).path), [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        json.removeValue(forKey: "attachments")
        XCTAssertEqual(try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: json)).media, [])
    }
}
