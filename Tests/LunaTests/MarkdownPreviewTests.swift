import AppKit
import XCTest
import LunaCore
@testable import Luna

final class MarkdownPreviewTests: XCTestCase {
    func testRendersMarkdownStructureAndUnicode() throws {
        let html = try MarkdownRenderer.body("""
        # Notes 🌙

        **Bold** and *italic* with [a link](https://example.com).

        - First
          - Nested
        - [x] Done

        > A quote

        ```swift
        let value = "<safe>"
        ```

        | Name | Value |
        | --- | --- |
        | Luna | 1 |
        """)
        for fragment in ["<h1>Notes 🌙</h1>", "<strong>Bold</strong>", "<em>italic</em>", "href=\"https://example.com\"",
                         "<ul>", "<li>Nested</li>", "type=\"checkbox\"", "<blockquote>", "<pre><code", "&lt;safe&gt;", "<table>"] {
            XCTAssertTrue(html.contains(fragment), fragment)
        }
    }
    func testRawHTMLAndImagesCannotInjectActiveContent() throws {
        let html = try MarkdownRenderer.body("""
        <script>alert('x')</script>

        <img src="https://example.com/tracker" onerror="alert(1)">

        ![Image](https://example.com/secret)
        """)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("<span>Image</span>"))
        let page = MarkdownRenderer.page(body: html, fontSize: 18, dark: true)
        XCTAssertTrue(page.contains("default-src 'none'"))
    }
    @MainActor func testPreviewPreservesEditsAndSelectionAndResetsForOtherFiles() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        let markdown = Note(text: "# Original", language: "Markdown")
        let code = Note(text: "let x = 1", language: "Swift")
        workspace.notes += [markdown, code]
        workspace.reloadShelf(); workspace.select(markdown.id)
        workspace.editor.setSelectedRange(NSRange(location: 10, length: 0))
        workspace.editor.insertText(" edited", replacementRange: workspace.editor.selectedRange())
        let source = workspace.editor.string
        let selection = workspace.editor.selectedRange()
        workspace.toggleMarkdownPreview()
        XCTAssertTrue(workspace.previewing)
        XCTAssertTrue(workspace.scroll.isHidden)
        XCTAssertFalse(workspace.markdownPreview.isHidden)
        workspace.toggleMarkdownPreview()
        XCTAssertEqual(workspace.editor.string, source)
        XCTAssertEqual(workspace.editor.selectedRange(), selection)
        XCTAssertTrue(workspace.editor.undoManager?.canUndo == true)
        workspace.toggleMarkdownPreview()
        workspace.select(code.id)
        XCTAssertFalse(workspace.previewing)
        XCTAssertFalse(workspace.scroll.isHidden)
        workspace.toggleMarkdownPreview()
        XCTAssertFalse(workspace.previewing)
        XCTAssertEqual(try workspace.store.load().first(where: { $0.id == markdown.id })?.text, source)
        workspace.close()
    }
}
