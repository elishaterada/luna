import AppKit
import WebKit
import XCTest
import LunaCore
@testable import Luna

final class NoteEmbedsTests: XCTestCase {
    func testEmbedParsingEscapesScriptsAndRespectsCodeBlocks() throws {
        let snippet = try XCTUnwrap(NoteEmbeds.insertion("<iframe src='https://example.com/embed?a=1&amp;b=2' onload='bad()'></iframe>"))
        XCTAssertEqual(snippet, "\n[Embed](https://example.com/embed?a=1&b=2)\n")
        XCTAssertNil(NoteEmbeds.insertion("<iframe src='javascript:alert(1)'></iframe>"))
        XCTAssertNil(NoteEmbeds.insertion("file:///private/secret"))
        XCTAssertFalse(NoteEmbeds.hasContent("```html\nhttps://example.com\n```"))
        let source = "Before\n\n" + snippet + "\nAfter"
        XCTAssertEqual(NoteEmbeds.blocks(source).map(\.source).joined(separator: "\n"), source)
        let page = MediaNoteView.page(Note(text: source + "\n<script>bad()</script>"), fontSize: 18, dark: true, pageID: "test")
        XCTAssertFalse(page.contains("<script>bad()"))
        XCTAssertTrue(page.contains("\\u003cscript>bad()"))

    }
    func testOEmbedUsesOnlySafeProviderURLs() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "video", "html": "<iframe src=\"https://player.example.com/123\" onload=\"bad()\"></iframe><script>bad()</script>"])
        XCTAssertEqual(EmbedResolver.responseURL(data)?.absoluteString, "https://player.example.com/123")
        XCTAssertNil(EmbedResolver.responseURL(try JSONSerialization.data(withJSONObject: ["type": "video", "html": "<script>bad()</script>"])))
    }
}
