import AppKit
import XCTest
@testable import Luna

final class NoteRefinementsTests: XCTestCase {
    func testEveryDirectoryResolvesToItsOwnPath() {
        let segments = NotePathView.segments(for: "/Users/someone/My Notes/draft.txt")
        XCTAssertEqual(segments.map(\.title), ["/", "Users", "someone", "My Notes", "draft.txt"])
        XCTAssertEqual(segments.compactMap { $0.url?.path }, ["/", "/Users", "/Users/someone", "/Users/someone/My Notes"])
        XCTAssertNil(segments.last?.url)
    }
    @MainActor func testHoverUnderlinesOnlyOneDirectoryAndKeepsItWhite() throws {
        let path = NotePathView()
        path.show(path: "/Users/someone/note.txt")
        let buttons = path.arrangedSubviews.compactMap { $0 as? DirectoryButton }
        let button = try XCTUnwrap(buttons.last)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        button.mouseEntered(with: event)
        for other in buttons {
            XCTAssertEqual(other.attributedTitle.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, other === button ? 1 : 0)
            XCTAssertEqual(other.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .white)
        }
        button.mouseExited(with: event)
        XCTAssertEqual(button.attributedTitle.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
    }
    func testMetadataTitlePriorityEntitiesAndFallbacks() {
        XCTAssertEqual(LinkMetadata.parseTitle("<title>Document title</title><meta content='Social &amp; title &#x1F319;' property='og:title'>"), "Social & title 🌙")
        XCTAssertEqual(LinkMetadata.parseTitle("<meta name='twitter:title' content='Twitter title'><title>Document</title>"), "Twitter title")
        XCTAssertEqual(LinkMetadata.parseTitle("<TITLE>  Hello\n world &mdash; today </TITLE>"), "Hello world — today")
        XCTAssertEqual(LinkMetadata.parseTitle("<script>const x = '<title>Fake</title>';</script><title>Real</title>"), "Real")
        XCTAssertNil(LinkMetadata.parseTitle("<html><body>No title</body></html>"))
        let details = LinkMetadata.parseDetails("""
            <html><head><meta content="Page &amp; title" property="og:title">
            <meta name="description" content="A useful &amp; short summary.">
            <meta property="og:image" content="/assets/cover.jpg?first=1&amp;second=2">
            <link href="/assets/icon.png" rel="shortcut icon"><title>Backup</title></head></html>
            """, baseURL: URL(string: "https://example.com/article")!)
        XCTAssertEqual(details.title, "Page & title")
        XCTAssertEqual(details.description, "A useful & short summary.")
        XCTAssertEqual(details.favicon?.absoluteString, "https://example.com/assets/icon.png")
        XCTAssertEqual(details.image?.absoluteString, "https://example.com/assets/cover.jpg?first=1&second=2")
        let secureImage = LinkMetadata.parseDetails("<meta property='og:image' content='http://example.com/cover.jpg'><meta property='og:image:secure_url' content='https://example.com/secure.jpg'>", baseURL: URL(string: "https://example.com")!)
        XCTAssertEqual(secureImage.image?.absoluteString, "https://example.com/secure.jpg")
        XCTAssertNil(LinkMetadata.parseDetails("<meta property='og:image' content='javascript:alert(1)'>", baseURL: URL(string: "https://example.com")!).image)
    }
}
