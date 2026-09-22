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
    func testEditorBulletsRenderAsNestedLists() throws {
        let source = "Nested list\n\n• First level\n  • Second level\n    • Third level\n• Last"
        let html = try MarkdownRenderer.body(source)
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 3, html)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 4, html)
        XCTAssertFalse(html.contains("•"), html)
        let flat = try MarkdownRenderer.body("• First\n•     Second\n•         Third")
        XCTAssertEqual(flat.components(separatedBy: "<li>").count - 1, 3, flat)
    }

    func testEditorBulletConversionPreservesCodeAndTaskOffsets() throws {
        let source = "```\n• Fenced\n```\n\n    • Code\n\nInline `• literal` and prose • literal.\n\n• Parent\n  - [ ] Child"
        let html = try MarkdownRenderer.body(source)
        XCTAssertTrue(html.contains("• Fenced"), html)
        XCTAssertTrue(html.contains("• Code"), html)
        XCTAssertTrue(html.contains("<code>• literal</code>"), html)
        XCTAssertTrue(html.contains("prose • literal"), html)
        XCTAssertTrue(html.contains("data-task-start=\"\((source as NSString).range(of: "[ ] Child").location)\""), html)
    }

    @MainActor func testPreviewPlacesNestedBulletsOnSeparateIndentedRows() async throws {
        _ = NSApplication.shared
        let preview = MarkdownPreview()
        preview.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        preview.show("• First\n  • Second\n    • Third", fontSize: 18, appearance: NSAppearance(named: .darkAqua)!)
        for _ in 0..<100 {
            if (try? await preview.evaluateJavaScript("document.querySelectorAll('li').length")) as? Int == 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let positions = try await preview.evaluateJavaScript("[...document.querySelectorAll('li')].map(e=>{const r=e.getBoundingClientRect();return [r.x,r.y]})")
        let rows = try XCTUnwrap(positions as? [[Double]])
        XCTAssertEqual(rows.count, 3)
        guard rows.count == 3 else { return }
        XCTAssertGreaterThan(rows[1][0], rows[0][0])
        XCTAssertGreaterThan(rows[2][0], rows[1][0])
        XCTAssertGreaterThan(rows[1][1], rows[0][1])
        XCTAssertGreaterThan(rows[2][1], rows[1][1])
    }

    func testEditorBulletsReturnToParentIndentation() throws {
        let html = try MarkdownRenderer.body("• First\n    • Second\n        • Third\n    • Sibling\n        • Child\n    • Last")
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 6, html)
        XCTAssertFalse(html.contains("•"), html)
    }

    func testShorthandTaskRows() throws {
        let html = try MarkdownRenderer.body("# Tasks\n\n[x] Done\n[] **Next**\n[ ] Later\n[X] Finished\n\n- [] Listed\n- [ ] Standard")
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 6)
        XCTAssertEqual(html.components(separatedBy: "checked=\"\"").count - 1, 2)
        XCTAssertTrue(html.contains("<strong>Next</strong>"))
        XCTAssertFalse(html.contains("[] Listed"))
    }

    func testTaskShorthandPreservesCodeAndInlineBrackets() throws {
        let html = try MarkdownRenderer.body("```text\n[] Code\n[x] Code\n```\n\n    [] Indented\n\nUse [] in prose and `[] inline`.\n\n[] <script>alert(1)</script>")
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 1)
        XCTAssertTrue(html.contains("[] Code"))
        XCTAssertTrue(html.contains("[] Indented"))
        XCTAssertTrue(html.contains("<code>[] inline</code>"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testTaskSourcePositionsExcludeCodeAndHandleUnicodeAndNesting() throws {
        let source = "🌙\n\n```\n[] Code\n```\n\n[] Same\n- [x] Same\n  - [] Nested\n\n> [ ] Quoted"
        let html = try MarkdownRenderer.body(source)
        XCTAssertEqual(html.components(separatedBy: "data-task-start=").count - 1, 4)
        XCTAssertFalse(html.contains("LUNATASK"))
        for label in ["[] Same", "[x] Same", "[] Nested", "[ ] Quoted"] {
            let location = (source as NSString).range(of: label).location
            XCTAssertTrue(html.contains("data-task-start=\"\(location)\""), html)
        }
    }

    @MainActor func testClickingPreviewTasksPersistsAndSupportsUndo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let note = Note(text: "🌙\n\n[] First\n[] Second", language: "Markdown")
        workspace.notes.append(note)
        workspace.reloadShelf(); workspace.select(note.id)
        workspace.toggleMarkdownPreview()
        let preview = workspace.markdownPreview
        for _ in 0..<100 {
            if let count = try? await preview.evaluateJavaScript("document.querySelectorAll('input[data-task-start]').length") as? Int, count == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let count = try await preview.evaluateJavaScript("document.querySelectorAll('input[data-task-start]').length") as? Int
        XCTAssertEqual(count, 2)
        for (index, expected) in [(0, "🌙\n\n[x] First\n[] Second"), (1, "🌙\n\n[x] First\n[x] Second"), (0, "🌙\n\n[ ] First\n[x] Second")] {
            _ = try await preview.evaluateJavaScript("document.querySelectorAll('input[data-task-start]')[\(index)].click(); true")
            for _ in 0..<100 {
                if workspace.editor.string == expected { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(workspace.editor.string, expected)
        }
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try workspace.store.load().first(where: { $0.id == note.id })?.text, workspace.editor.string)
        workspace.toggleMarkdownPreview()
        XCTAssertTrue(workspace.editor.undoManager?.canUndo == true)
        workspace.editor.undoManager?.undo()
        XCTAssertNotEqual(workspace.editor.string, "🌙\n\n[ ] First\n[x] Second")
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
