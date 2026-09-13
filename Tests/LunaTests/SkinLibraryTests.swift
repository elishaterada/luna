// Regression coverage adapted alongside Sora’s local skin library.
import AppKit
import AVFoundation
import XCTest
@testable import Luna

final class SkinLibraryTests: XCTestCase {
    @MainActor func testVideoImportPreparesPosterAndStartsMuted() async throws {
        let root = try fixture()
        let source = try XCTUnwrap(Bundle.module.url(forResource: "skin", withExtension: "mp4", subdirectory: "Fixtures"))
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        let skin = try await library.add(source)
        XCTAssertEqual(skin.kind, .video)
        XCTAssertTrue(skin.hasAudio)
        XCTAssertTrue(skin.muted)
        XCTAssertNotNil(NSImage(contentsOf: library.posterURL(for: skin)))
        let asset = AVURLAsset(url: library.url(for: skin))
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luna-skins-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func photo(at url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    private func transparentPhoto(at url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 0]
        for (index, value) in pixels.enumerated() { bitmap.bitmapData![index] = value }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    private func assertTransparentPreview(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)), file: file, line: line)
        XCTAssertEqual(url.pathExtension, "png", file: file, line: line)
        XCTAssertEqual(image.pixelsWide, 2, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 1, y: 0)).alphaComponent, 0, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01, file: file, line: line)
    }
    @MainActor func testPNGAndWebPImportsPreserveTransparencyAndPerSkinColors() async throws {
        let root = try fixture(), png = root.appendingPathComponent("transparent.png")
        try transparentPhoto(at: png)
        // Original 2×1 lossless WebP fixture: one opaque red pixel and one transparent pixel.
        let webp = root.appendingPathComponent("transparent.webp")
        try XCTUnwrap(Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TBAAAAAvAQAAEA8Q8x/zH4yM6H8A")).write(to: webp)
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        let first = try await library.add(png), second = try await library.add(webp)
        for skin in [first, second] { try assertTransparentPreview(library.posterURL(for: skin)) }
        library.update { $0.skins[0].backgroundRGB = 0x123456; $0.skins[1].backgroundRGB = 0xFEDCBA }
        library.select(first.id)
        XCTAssertEqual(library.configuration.selected?.backgroundRGB, 0x123456)
        library.select(second.id)
        XCTAssertEqual(library.configuration.selected?.backgroundRGB, 0xFEDCBA)
        try FileManager.default.removeItem(at: png)
        try FileManager.default.removeItem(at: webp)
        let reopened = SkinLibrary(root: library.root, startsTimer: false)
        await reopened.waitForPhotoPreviews()
        XCTAssertEqual(reopened.configuration, library.configuration)
        reopened.update { $0.skins[1].backgroundRGB = nil }
        XCTAssertNil(reopened.configuration.selected?.backgroundRGB)
        XCTAssertEqual(reopened.configuration.skins[0].backgroundRGB, 0x123456)
    }
    @MainActor func testLegacyJPEGPreviewIsRebuiltFromRetainedOriginalWithoutChangingCatalog() async throws {
        let root = try fixture(), source = root.appendingPathComponent("transparent.png")
        try transparentPhoto(at: source)
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        let skin = try await library.add(source)
        let png = library.posterURL(for: skin)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: png)))
        try XCTUnwrap(image.representation(using: .jpeg, properties: [:])).write(to: png.deletingLastPathComponent().appendingPathComponent("poster.jpg"))
        try FileManager.default.removeItem(at: png)
        try FileManager.default.removeItem(at: source)
        let manifest = library.root.appendingPathComponent("library.json"), before = try Data(contentsOf: manifest)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("backgroundRGB"))
        let reopened = SkinLibrary(root: library.root, startsTimer: false)
        await reopened.waitForPhotoPreviews()
        XCTAssertFalse(reopened.loadFailed)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertNil(reopened.configuration.selected?.backgroundRGB)
        try assertTransparentPreview(reopened.posterURL(for: skin))
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }
    @MainActor func testMissingLegacyOriginalDoesNotBlockOtherPreviewRepairs() async throws {
        let root = try fixture(), source = root.appendingPathComponent("transparent.png")
        try transparentPhoto(at: source)
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        let missing = try await library.add(source), healthy = try await library.add(source)
        try FileManager.default.removeItem(at: library.posterURL(for: missing))
        try FileManager.default.removeItem(at: library.posterURL(for: healthy))
        try FileManager.default.removeItem(at: library.url(for: missing))
        let reopened = SkinLibrary(root: library.root, startsTimer: false)
        await reopened.waitForPhotoPreviews()
        XCTAssertNotNil(reopened.errorMessage)
        try assertTransparentPreview(reopened.posterURL(for: healthy))
        XCTAssertEqual(reopened.configuration.skins.count, 2)
    }
    func testBackgroundColorClampsWideGamutAndFollowsThemeWhenReset() throws {
        let wide = NSColor(srgbRed: 1.2, green: -0.2, blue: 0.5, alpha: 0.3)
        XCTAssertEqual(EditorSkin.backgroundRGB(from: wide), 0xFF0080)
        var skin = EditorSkin(id: UUID(), name: "Photo", filename: "original.png", kind: .photo, hasAudio: false)
        XCTAssertNotEqual(skin.backgroundColor(light: true), skin.backgroundColor(light: false))
        skin.backgroundRGB = 0x123456
        XCTAssertEqual(skin.backgroundColor(light: true), skin.backgroundColor(light: false))
        XCTAssertEqual(EditorSkin.backgroundRGB(from: skin.backgroundColor(light: false)), 0x123456)
    }
    @MainActor func testCopiesPhotoSurvivesSourceDeletionAndRelaunchThenRemovesOwnedCopy() async throws {
        let root = try fixture(), source = root.appendingPathComponent("photo.png")
        try photo(at: source)
        let original = try Data(contentsOf: source)
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        let skin = try await library.add(source)
        XCTAssertEqual(skin.kind, .photo)
        XCTAssertEqual(library.configuration.selectedID, skin.id)
        XCTAssertTrue(library.configuration.enabled)
        XCTAssertNotEqual(source, library.url(for: skin))
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: library.url(for: skin)), original)
        XCTAssertNotNil(NSImage(contentsOf: library.posterURL(for: skin)))
        library.update { $0.readability = 0.85; $0.perspective = true; $0.rotationSeconds = 60 }
        let reopened = SkinLibrary(root: library.root, startsTimer: false)
        XCTAssertEqual(reopened.configuration, library.configuration)
        reopened.remove(skin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: skin).path))
        XCTAssertTrue(reopened.configuration.skins.isEmpty)
        XCTAssertFalse(reopened.configuration.enabled)
    }
    @MainActor func testRejectsCorruptAndSymlinkMediaWithoutPublishingOrLeavingStagingFiles() async throws {
        let root = try fixture(), source = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: source)
        let library = SkinLibrary(root: root.appendingPathComponent("library"), startsTimer: false)
        do { try await library.add(source); XCTFail("Accepted corrupt media") } catch { }
        XCTAssertTrue(library.configuration.skins.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.root.path), [])
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { try await library.add(link); XCTFail("Accepted symlink") } catch { }
    }
    @MainActor func testCorruptCatalogIsPreservedAndSaveFailureDoesNotPublishChanges() throws {
        let root = try fixture(), manifest = root.appendingPathComponent("library.json")
        let invalid = Data("invalid catalog".utf8)
        try invalid.write(to: manifest)
        let library = SkinLibrary(root: root, startsTimer: false)
        XCTAssertTrue(library.loadFailed)
        library.update { $0.readability = 0.9 }
        XCTAssertEqual(try Data(contentsOf: manifest), invalid)
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        let unavailable = SkinLibrary(root: blocker, startsTimer: false)
        unavailable.update { $0.readability = 0.9 }
        XCTAssertEqual(unavailable.configuration.readability, 0.65)
        XCTAssertNotNil(unavailable.errorMessage)
    }
    @MainActor func testInvalidCatalogCannotActivateUnvalidatedMedia() throws {
        let root = try fixture()
        let invalid = EditorSkin(id: UUID(), name: "Invalid", filename: "../../outside.mp4", kind: .video, hasAudio: true)
        let config = SkinConfiguration(skins: [invalid, invalid], selectedID: invalid.id, enabled: true)
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent("library.json"))
        let library = SkinLibrary(root: root, startsTimer: false)
        XCTAssertTrue(library.loadFailed)
        XCTAssertTrue(library.configuration.skins.isEmpty)
        XCTAssertFalse(library.configuration.enabled)
    }

    func testRotationSkipsElapsedIntervalsAndPreservesDisabledSelection() {
        let a = EditorSkin(id: UUID(), name: "A", filename: "original.png", kind: .photo, hasAudio: false)
        let b = EditorSkin(id: UUID(), name: "B", filename: "original.mp4", kind: .video, hasAudio: true)
        let anchor = Date(timeIntervalSince1970: 1000)
        var config = SkinConfiguration(skins: [a, b], selectedID: a.id, enabled: true, rotationSeconds: 60, rotationAnchor: anchor)
        config.rotate(at: anchor.addingTimeInterval(59)); XCTAssertEqual(config.selectedID, a.id)
        config.rotate(at: anchor.addingTimeInterval(180)); XCTAssertEqual(config.selectedID, b.id)
        config.enabled = false
        config.rotate(at: anchor.addingTimeInterval(240)); XCTAssertEqual(config.selectedID, b.id)
        config.readability = .nan; config.rotationSeconds = -1; config.normalize()
        XCTAssertEqual(config.readability, 0.65); XCTAssertEqual(config.rotationSeconds, 0)
    }
}
