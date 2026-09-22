import AppKit
import XCTest
import LunaCore
@testable import Luna

final class MarkdownEditingTests: XCTestCase {
    @MainActor private func workspace() throws -> Workspace {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        addTeardownBlock { @MainActor in workspace.close(); try? FileManager.default.removeItem(at: root) }
        return workspace
    }

    @MainActor func testMarkdownShortcutsWrapToggleAndUndo() throws {
        let workspace = try workspace()
        let note = Note(text: "Hello 🌙", language: "Markdown")
        workspace.notes.append(note); workspace.select(note.id, focusContent: true)
        let editor = workspace.editor
        editor.setSelectedRange(NSRange(location: 6, length: 2))
        let menu = NSMenu()
        let bold = NSMenuItem(title: "Bold", action: #selector(Workspace.markdownBold), keyEquivalent: "b")
        bold.target = workspace; menu.addItem(bold)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: workspace.window!.windowNumber, context: nil, characters: "b",
            charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "Hello **🌙**")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 2))
        undo.undo(); XCTAssertEqual(editor.string, note.text)
        undo.redo(); XCTAssertEqual(editor.string, "Hello **🌙**")
        editor.setSelectedRange(NSRange(location: 8, length: 2))
        workspace.markdownItalic(); XCTAssertEqual(editor.string, "Hello ***🌙***")
        workspace.markdownItalic(); XCTAssertEqual(editor.string, "Hello **🌙**")
        workspace.markdownBold(); XCTAssertEqual(editor.string, note.text)
        workspace.markdownItalic(); XCTAssertEqual(editor.string, "Hello *🌙*")
        workspace.markdownItalic(); XCTAssertEqual(editor.string, note.text)
        workspace.markdownCode(); XCTAssertEqual(editor.string, "Hello `🌙`")
        workspace.markdownCode(); XCTAssertEqual(editor.string, note.text)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        workspace.markdownBold()
        XCTAssertEqual(editor.string, "****Hello 🌙")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
    }

    @MainActor func testSplitPreviewKeepsSourceEditableAndUpdates() async throws {
        let workspace = try workspace()
        let note = Note(text: "# Source\n\nText", language: "Markdown")
        workspace.notes.append(note); workspace.select(note.id)
        workspace.showWindow(nil)
        workspace.toggleSplitPreview()
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(workspace.splitPreviewing)
        XCTAssertFalse(workspace.scroll.isHidden)
        XCTAssertFalse(workspace.markdownPreview.isHidden)
        XCTAssertEqual(workspace.editor.string, note.text)
        XCTAssertTrue(workspace.window?.firstResponder === workspace.editor)
        XCTAssertLessThanOrEqual(workspace.scroll.frame.maxX, workspace.markdownPreview.frame.minX)
        workspace.editor.setSelectedRange(NSRange(location: (note.text as NSString).length, length: 0))
        workspace.editor.insertText(" updated", replacementRange: workspace.editor.selectedRange())
        for _ in 0..<100 {
            if (try? await workspace.markdownPreview.evaluateJavaScript("document.body.innerText.includes('Text updated')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let rendered = try await workspace.markdownPreview.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(rendered?.contains("Text updated") == true)
        XCTAssertTrue(workspace.flushRecovery())
        XCTAssertEqual(try workspace.store.load().first(where: { $0.id == note.id })?.text, note.text + " updated")
        workspace.toggleSplitPreview()
        XCTAssertTrue(workspace.markdownPreview.isHidden)
        XCTAssertFalse(workspace.scroll.isHidden)
        workspace.toggleSplitPreview()
        workspace.toggleMarkdownPreview()
        XCTAssertFalse(workspace.splitPreviewing)
        XCTAssertTrue(workspace.previewing)
        XCTAssertTrue(workspace.scroll.isHidden)
        let plain = Note(text: "Plain", language: "Plain Text")
        workspace.notes.append(plain); workspace.select(plain.id, focusContent: true)
        workspace.toggleSplitPreview(); workspace.markdownBold()
        XCTAssertFalse(workspace.splitPreviewing)
        XCTAssertEqual(workspace.editor.string, "Plain")
    }
    @MainActor func testSplitScrollingBothDirectionsAndRefresh() async throws {
        let workspace = try workspace()
        let text = (0..<150).map { "## Heading \($0)\n\nParagraph with **bold** text.\n" }.joined(separator: "\n")
        let note = Note(text: text, language: "Markdown")
        workspace.notes.append(note); workspace.select(note.id)
        workspace.showWindow(nil); workspace.toggleSplitPreview()
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let preview = workspace.markdownPreview
        for _ in 0..<100 {
            if (try? await preview.evaluateJavaScript("document.querySelectorAll('h2').length")) as? Int == 150 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let clip = workspace.scroll.contentView
        let maximum = workspace.editor.frame.height - clip.bounds.height
        XCTAssertGreaterThan(maximum, 0)
        clip.scroll(to: NSPoint(x: 0, y: maximum * 0.5))
        workspace.scroll.reflectScrolledClipView(clip)
        workspace.viewportChanged()
        try await Task.sleep(nanoseconds: 200_000_000)
        let fractionScript = "scrollY / (document.documentElement.scrollHeight - innerHeight)"
        let fraction = try await preview.evaluateJavaScript(fractionScript) as! Double
        XCTAssertEqual(fraction, 0.5, accuracy: 0.01)
        _ = try await preview.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(clip.bounds.origin.y / (workspace.editor.frame.height - clip.bounds.height), 1, accuracy: 0.01)
        preview.show(text + "\nUpdated", fontSize: 18, appearance: NSApp.effectiveAppearance, preservingScroll: true)
        for _ in 0..<100 {
            if (try? await preview.evaluateJavaScript("document.body.innerText.includes('Updated')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let refreshed = try await preview.evaluateJavaScript(fractionScript) as! Double
        XCTAssertEqual(refreshed, 1, accuracy: 0.01)
        _ = try await preview.evaluateJavaScript("window.scrollTo(0, 0)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 1)
    }

}
