import XCTest
@testable import LunaCore

final class RecoveryTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testRecoveryPreservesUnsavedFileEditsAndPrivatePermissions() throws {
        let store = try RecoveryStore(directory: directory.appendingPathComponent("recovery"))
        var note = Note(text: "API_KEY=秘密\n", path: "/tmp/.env", language: "Environment")
        note.dirty = true
        try store.save(note)
        let recovered = try XCTUnwrap(store.load().first)
        XCTAssertEqual(recovered.text, note.text); XCTAssertEqual(recovered.id, note.id)
        XCTAssertTrue(recovered.dirty); XCTAssertEqual(recovered.path, note.path)
        let file = store.directory.appendingPathComponent(note.id.uuidString + ".json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        note.text = "updated"; try store.save(note)
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertEqual(try store.load().first?.text, "updated")
    }
    func testFileRoundTripRetainsCRLFAndPermissions() throws {
        let url = directory.appendingPathComponent(".zshrc")
        let source = "# shell\r\nexport NAME=\"Luna 🌙\"\r\n"
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        var note = try TextFile.read(url)
        XCTAssertEqual(note.language, "Shell")
        note.text += "# changed\r\n"
        try TextFile.write(note, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), note.text)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }
    func testUTF16RoundTripAndBinaryRejection() throws {
        let url = directory.appendingPathComponent("test.txt")
        try "Hello 日本語".data(using: .utf16)!.write(to: url)
        let note = try TextFile.read(url)
        XCTAssertEqual(note.text, "Hello 日本語")
        try TextFile.write(note, to: url)
        XCTAssertEqual(try TextFile.read(url).text, note.text)
        try Data([0x00, 0xff, 0x01, 0x02]).write(to: url)
        XCTAssertThrowsError(try TextFile.read(url))
    }
    func testCorruptRecordDoesNotHideHealthyNotes() throws {
        let store = try RecoveryStore(directory: directory)
        try store.save(Note(text: "still here"))
        let broken = directory.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: broken)
        XCTAssertEqual(try store.load().first?.text, "still here")
        XCTAssertEqual(store.unreadableFiles.map { $0.resolvingSymlinksInPath() }, [broken.resolvingSymlinksInPath()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }
    func testLanguageDetectionAndNoteTitle() {
        XCTAssertEqual(Note.language(for: URL(fileURLWithPath: "/tmp/.env.local")), "Environment")
        XCTAssertEqual(Note.language(for: URL(fileURLWithPath: "/tmp/a.yaml")), "YAML")
        XCTAssertEqual(Note(text: "\nMeeting notes\nScenario 1").title, "Meeting notes")
    }
    func testRecoveryDeletionDoesNotDeleteOriginal() throws {
        let original = directory.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: original)
        let store = try RecoveryStore(directory: directory.appendingPathComponent("recovery"))
        let note = try TextFile.read(original)
        try store.save(note); try store.remove(note.id)
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
}
