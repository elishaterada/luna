import AppKit
import XCTest
import LunaCore
@testable import Luna

final class EditorBehaviorTests: XCTestCase {
    private func preference(_ key: String, _ value: Any) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.set(value, forKey: key)
        addTeardownBlock {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    @MainActor func testIndentationCanBeContinuedOrDisabled() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        preference("editor.autoIndent", true)
        editor.string = "  hello"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "  hello\n  ")
        preference("editor.autoIndent", false)
        editor.string = "  hello"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "  hello\n")
    }
    @MainActor func testTabInsertionRespectsSpacesAndLiteralTabs() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  ")
        preference("editor.useTabs", true)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  \t")
    }
    @MainActor func testTabIndentsListMarkersAndShiftTabOutdents() {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        let editor = EditorView(usingTextLayoutManager: true)
        for marker in ["• ", "12. ", "☐ "] {
            editor.string = marker + "Item"
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertTab(nil)
            XCTAssertEqual(editor.string, "  " + marker + "Item")
            editor.insertTab(nil)
            XCTAssertEqual(editor.string, "    " + marker + "Item")
            editor.insertBacktab(nil)
            XCTAssertEqual(editor.string, "  " + marker + "Item")
            editor.insertNewline(nil)
            XCTAssertTrue(editor.string.hasSuffix("\n  " + (marker == "12. " ? "13. " : marker)))
        }
        preference("editor.useTabs", true)
        editor.string = "• Item"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "\t• Item")
        XCTAssertEqual(editor.selectedRange().location, 3)
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, "• Item")
        XCTAssertEqual(editor.selectedRange().location, 2)
        editor.string = "```\n• code"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "```\n• code\t")
    }
    @MainActor func testSelectedListsIndentTogetherWithoutReplacingText() {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        let editor = EditorView(usingTextLayoutManager: true)
        let original = "• First 🌙\n  • Child\n12. Last\nOutside"
        editor.string = original
        let selectedLength = (original as NSString).range(of: "Outside").location
        editor.setSelectedRange(NSRange(location: 0, length: selectedLength))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  • First 🌙\n    • Child\n  12. Last\nOutside")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: selectedLength + 6))
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: selectedLength))
        preference("editor.useTabs", true)
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "\t• First 🌙\n\t  • Child\n\t12. Last\nOutside")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.string, original)
    }

    @MainActor func testPartialListSelectionPreservesProseAndFencedCode() {
        _ = NSApplication.shared
        preference("editor.tabWidth", 2)
        preference("editor.useTabs", false)
        let editor = EditorView(usingTextLayoutManager: true)
        editor.string = "• First\nProse\n```\n• Code\n```\n☐ Last"
        editor.setSelectedRange(NSRange(location: 3, length: (editor.string as NSString).length - 5))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "  • First\nProse\n```\n• Code\n```\n  ☐ Last")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (editor.string as NSString).length))
    }

    @MainActor func testSelectedListIndentCanBeUndoneAsOneEdit() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let editor = workspace.editor
        editor.formatsLists = true // Exercise the list utility with the workspace's undo manager.
        editor.string = "• First\n• Second"
        let original = editor.string
        editor.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        undo.beginUndoGrouping()
        editor.insertTab(nil)
        undo.endUndoGrouping()
        XCTAssertNotEqual(editor.string, original)
        undo.undo()
        XCTAssertEqual(editor.string, original)
        undo.redo()
        XCTAssertTrue(editor.string.contains("• First\n"))
        XCTAssertTrue(editor.string.hasSuffix("• Second"))
    }

    @MainActor func testListBackspaceTreatsMarkerAndGapAsOneUnit() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        for marker in ["• ", "12. ", "☐ ", "☑ "] {
            editor.string = "    " + marker + "Text"
            editor.setSelectedRange(NSRange(location: ("    " + marker as NSString).length, length: 0))
            editor.deleteBackward(nil)
            XCTAssertEqual(editor.string, "Text")
            XCTAssertEqual(editor.selectedRange().location, 0)
            editor.string = "• First\n    " + marker
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.deleteBackward(nil)
            XCTAssertEqual(editor.string, "• First")
            editor.string = marker + "Text"
            editor.setSelectedRange(NSRange(location: (marker as NSString).length - 1, length: 1))
            editor.deleteBackward(nil)
            XCTAssertEqual(editor.string, "Text", "Selecting the marker separator must not make it independently deletable")
        }
        editor.string = "    • First"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "    • First\n    • ")
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "    • First")
        editor.string = "• First\n• \n• Last"
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• First\n• Last")
        editor.string = "• \n• Last"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• Last")
        editor.string = "• First\r\n• "
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• First")
        editor.string = "• Text"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "• Tex")
        editor.string = "```\n• Code"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "```\n•Code")
    }

    @MainActor func testPresentationZoomIsVisibleAndPreservesNormalSize() throws {
        _ = NSApplication.shared
        preference("editor.fontSize", 18.0)
        preference("editor.presentationSize", 26.0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
                                  skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        workspace.togglePresentation()
        XCTAssertEqual(workspace.editor.font?.pointSize, 26)
        workspace.larger()
        XCTAssertEqual(workspace.editor.font?.pointSize, 28)
        workspace.smaller(); workspace.smaller()
        XCTAssertEqual(workspace.editor.font?.pointSize, 26)
        workspace.togglePresentation()
        XCTAssertEqual(workspace.editor.font?.pointSize, 18)
        XCTAssertEqual(EditorPreferences.fontSize, 18)
        workspace.close()
    }
    @MainActor func testInvalidNumericPreferencesHaveSafeBounds() {
        preference("editor.padding", -20.0)
        preference("editor.presentationSize", 100.0)
        preference("editor.lineSpacing", Double.nan)
        XCTAssertEqual(EditorPreferences.editorPadding, 16)
        XCTAssertEqual(EditorPreferences.presentationSize, 60)
        XCTAssertEqual(EditorPreferences.lineSpacing, 0.3)
    }
}

extension EditorBehaviorTests {
    @MainActor func testMarkdownSourceDisplaysLiteralUnstyledText() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let note = Note(text: "# Heading\n• Item\n1. **bold**\n[Mention](https://example.com)", language: "Markdown")
        workspace.notes.append(note); workspace.select(note.id)
        workspace.showWindow(nil); workspace.toggleMarkdownPreview()
        let editor = workspace.editor
        XCTAssertEqual(editor.string, note.text)
        XCTAssertFalse(editor.formatsLists, "Source must not style or convert list prefixes")
        let content = try XCTUnwrap(editor.textLayoutManager?.textContentManager as? NSTextContentStorage)
        let row = (note.text as NSString).lineRange(for: (note.text as NSString).range(of: "• Item"))
        XCTAssertNil(editor.textContentStorage(content, textParagraphWith: row), "Source must use normal paragraph geometry and font")
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.highlighter.highlight(editor)
        var colors: [NSColor] = []
        editor.textLayoutManager?.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, _ in
            if let color = attributes[.foregroundColor] as? NSColor { colors.append(color) }
            return true
        }
        XCTAssertFalse(colors.isEmpty)
        XCTAssertTrue(colors.allSatisfy { $0 == Theme.text }, "Source must not color Markdown syntax")
        editor.setSelectedRange(NSRange(location: 0, length: (note.text as NSString).length))
        editor.insertText("- ", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "- ", "Source typing must retain the literal marker")
        editor.insertText("item", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "- item\n", "Source Return must not insert a list marker")
    }
    @MainActor func testTypingImmediatelyAfterCreatingNotePreservesFirstCharacter() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil); workspace.newNote()
        let window = try XCTUnwrap(workspace.window)
        for character in "List spacing check" {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: character == "L" ? .shift : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character).lowercased(), isARepeat: false, keyCode: 0))
            window.sendEvent(event)
        }
        for _ in 0..<100 {
            if workspace.editor.string == "List spacing check" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(workspace.editor.string, "List spacing check")
    }
    @MainActor func testPlainTextModeKeepsMarkersAndPastedLinksLiteral() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root), skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        let note = Note(text: "• Item\n[Mention](https://example.com)", language: "Plain Text")
        workspace.notes.append(note); workspace.select(note.id, focusContent: true)
        XCTAssertFalse(workspace.richEditing)
        XCTAssertFalse(workspace.editor.formatsLists)
        let editor = workspace.editor
        editor.setSelectedRange(NSRange(location: (note.text as NSString).length, length: 0))
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let previous { pasteboard.setString(previous, forType: .string) } }
        pasteboard.clearContents(); pasteboard.setString("https://example.com", forType: .string)
        editor.paste(nil)
        XCTAssertEqual(editor.string, note.text + "https://example.com")
        XCTAssertFalse(workspace.richEditing)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "• Item\n\n[Mention](https://example.com)https://example.com")
    }
    @MainActor func testListsFormatContinueExitAndKeepCodeLiteral() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        editor.insertText("- ", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "- ")
        editor.insertText("[ ] Task", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "☐ Task")
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n☐ ")
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n")
        editor.insertText("3) Third", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "☐ Task\n3. Third\n4. ")
        editor.formatsLists = false
        editor.string = ""; editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("- literal", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "- literal")
        XCTAssertEqual(NoteLists.formatted("- [x] Done\n* Item\n```\n- code\n```"), "☑ Done\n* Item\n```\n- code\n```")
        for marker in ["-", "*", "+", "•"] {
            XCTAssertEqual(NoteLists.formatted("\(marker) Item"), "\(marker) Item")
            XCTAssertEqual(NoteLists.continuation("  \(marker) Item")?.prefix, "  \(marker) ")
        }
    }
    @MainActor func testEditMenuSelectAllStillWorksInRegularEditor() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        try store.save(Note(text: "Ordinary text"))
        let workspace = Workspace(store: store, skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        workspace.window?.makeFirstResponder(workspace.editor)
        let delegate = AppDelegate(); delegate.workspace = workspace
        delegate.selectAllContent(nil)
        XCTAssertEqual(workspace.editor.selectedRange(), NSRange(location: 0, length: 13))
    }
    @MainActor func testSourceKeepsSlashCommandsLiteral() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(store: try RecoveryStore(directory: root.appendingPathComponent("Recovery")),
            skinLibrary: SkinLibrary(root: root.appendingPathComponent("Skins"), startsTimer: false))
        defer { workspace.close() }
        workspace.showWindow(nil)
        workspace.toggleMarkdownPreview()
        let editor = workspace.editor
        workspace.window?.makeFirstResponder(editor)
        editor.insertText("/h2", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(editor.slashMenuVisible)
        XCTAssertEqual(editor.string, "/h2")
        editor.insertNewline(nil)
        editor.insertText("/bullet", replacementRange: editor.selectedRange())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(editor.slashMenuVisible)
        XCTAssertEqual(editor.string, "/h2\n/bullet")
    }
}
