import AppKit
import LunaCore
import Combine

final class WorkspaceSession {
    var notes: [Note] = []
    var pendingMediaImports = 0
    let windows = NSHashTable<Workspace>.weakObjects()
    let diskQueue = DispatchQueue(label: "dev.luna.recovery", qos: .utility)
}

final class Workspace: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let session: WorkspaceSession
    var notes: [Note] {
        get { session.notes }
        set {
            session.notes = newValue.filter(\.isPinned) + newValue.filter { !$0.isPinned }
            for other in session.windows.allObjects where other !== self { other.receiveNotes() }
        }
    }
    private var additionalWindows: [Workspace] = []
    private var sharingPicker: NSSharingServicePicker?
    private var actionNoteID: UUID?
    var selectedID: UUID?
    let store: RecoveryStore
    var diskQueue: DispatchQueue { session.diskQueue }
    var recoveryTask: DispatchWorkItem?
    var highlightTask: DispatchWorkItem?
    let highlighter = SyntaxHighlighter()
    let editor = EditorView(usingTextLayoutManager: true)
    let scroll = NSScrollView()
    let markdownPreview = MarkdownPreview()
    let mediaView = MediaNoteView()
    private(set) var richEditing = false
    private var previewButton: ChromeButton!
    private(set) var previewing = false
    let table = NoteListView()
    let sidebar = Surface(Theme.panel)
    let main = Surface(Theme.background)
    let skinBackground = SkinBackgroundView()
    let windowFrost = WindowFrostView()
    let effects = EditorEffectsView()
    let skins: SkinLibrary
    private var skinObservation: AnyCancellable?
    private var footerInset: NSLayoutConstraint!
    private var footerTrailing: NSLayoutConstraint!
    private var dividerInset: NSLayoutConstraint!
    private var dividerTrailing: NSLayoutConstraint!
    private var presentationButton: ChromeButton!
    private var sidebarButton: ChromeButton!
    private var smallerButton: ChromeButton!
    private var largerButton: ChromeButton!

    let heading = Theme.label("Untitled note", size: 14, color: Theme.text, weight: .medium)
    let notePath = NotePathView()
    let subtitle = Theme.label("Private note · kept on this Mac", size: 11)
    let status = Theme.label("All notes stay with you", size: 11)
    let updated = Theme.label("", size: 11)
    let position = Theme.label("Ln 1, Col 1", size: 11)
    let language = NSPopUpButton()
    let sizeLabel = Theme.label("18 pt", size: 11)
    var sidebarWidth: NSLayoutConstraint!
    var headerInset: NSLayoutConstraint!
    var fontSize: CGFloat = EditorPreferences.fontSize
    var notesVisible = true
    var presenting = false
    private var presentationFontSize: CGFloat?
    private var displayedFontSize: CGFloat {
        presenting ? max(EditorPreferences.presentationSize, presentationFontSize ?? fontSize) : fontSize
    }
    private var minimumDisplayedSize: CGFloat { presenting ? EditorPreferences.presentationSize : 12 }
    private var maximumDisplayedSize: CGFloat { presenting ? 60 : 48 }
    var loading = false
    var reloadingShelf = false
    var lastRecoveryError: Error?
    var index: Int? { notes.firstIndex { $0.id == selectedID } }

    init(store: RecoveryStore, skinLibrary: SkinLibrary? = nil, session: WorkspaceSession? = nil) {
        self.session = session ?? WorkspaceSession()
        self.store = store
        let skinRoot = ProcessInfo.processInfo.environment["LUNA_RECOVERY_DIR"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("Skins", isDirectory: true)
        }
        skins = skinLibrary ?? skinRoot.map { SkinLibrary(root: $0) } ?? SkinLibrary()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        let dropRoot = FileDropView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        dropRoot.onFileDrop = { [weak self] urls in self?.openDroppedFiles(urls) }
        window.contentView = dropRoot
        window.title = "Luna"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        window.appearance = EditorPreferences.nsAppearance
        window.minSize = NSSize(width: 820, height: 460); window.isReleasedWhenClosed = false
        window.delegate = self; window.setFrameAutosaveName(ProcessInfo.processInfo.environment["LUNA_RECOVERY_DIR"] == nil ? "LunaWorkspace" : "LunaReviewWorkspace"); window.center()
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(applyPreferences), name: EditorPreferences.changed, object: nil)
        applyPreferences()
        skinObservation = skins.$configuration.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applySkin() }
        applySkin()
        if session == nil { do { notes = try store.load() } catch { showError(error) } }
        if !store.unreadableFiles.isEmpty {
            let alert = NSAlert(); alert.messageText = "Some notes could not be recovered."
            alert.informativeText = "Luna kept the unreadable recovery files untouched in \(store.directory.path). Other notes are available."
            alert.runModal()
        }
        if notes.isEmpty { notes = [Note()] }
        self.session.windows.add(self)
        reloadShelf(); select(notes[0].id)
    }
    required init?(coder: NSCoder) { fatalError() }

    func buildUI() {
        guard let root = window?.contentView else { return }
        windowFrost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(windowFrost)
        NSLayoutConstraint.activate([
            windowFrost.leadingAnchor.constraint(equalTo: root.leadingAnchor), windowFrost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            windowFrost.topAnchor.constraint(equalTo: root.topAnchor), windowFrost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        skinBackground.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(skinBackground)
        NSLayoutConstraint.activate([
            skinBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor), skinBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            skinBackground.topAnchor.constraint(equalTo: root.topAnchor), skinBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        effects.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(effects)
        NSLayoutConstraint.activate([
            effects.leadingAnchor.constraint(equalTo: root.leadingAnchor), effects.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            effects.topAnchor.constraint(equalTo: root.topAnchor), effects.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        [sidebar, main].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Theme.Layout.sidebarWidth)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebarWidth,
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor), main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let brand = Theme.label("Luna", size: 20, color: Theme.mint, weight: .medium)
        let shelfTitle = Theme.label("Notes", size: 13, weight: .semibold)
        let add = Theme.button("plus", label: "New note (⌘N)", target: self, action: #selector(newNote))
        let shelfHeader = NSStackView(views: [shelfTitle, NSView(), add]); shelfHeader.orientation = .horizontal
        let shelfScroll = NSScrollView(); shelfScroll.drawsBackground = false; shelfScroll.backgroundColor = Theme.panel; shelfScroll.hasVerticalScroller = true; shelfScroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("note")); table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = Theme.Layout.rowHeight; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .plain; table.backgroundColor = .clear; table.selectionHighlightStyle = .regular; table.delegate = self; table.dataSource = self
        window?.acceptsMouseMovedEvents = true
        table.setAccessibilityLabel("Notes and open files"); shelfScroll.documentView = table
        table.focusContent = { [weak self] in self?.focusContent() }
        table.registerForDraggedTypes([Self.noteDragType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.menu = makeNoteActionsMenu()
        let local = Theme.label("Stored on this Mac", size: 11)
        for view in [brand, shelfHeader, shelfScroll, local] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 56), brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            shelfHeader.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 24), shelfHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24), shelfHeader.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -24),
            shelfScroll.topAnchor.constraint(equalTo: shelfHeader.bottomAnchor, constant: 8), shelfScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), shelfScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12), shelfScroll.bottomAnchor.constraint(equalTo: local.topAnchor, constant: -16),
            local.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 28), local.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -24)
        ])
        let titleStack = NSStackView(views: [heading, subtitle, notePath, updated]); titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 8
        sidebarButton = Theme.button("sidebar.left", label: "Hide notes (⌘⌥S)", target: self, action: #selector(toggleSidebar))
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarButton)
        NSLayoutConstraint.activate([
            sidebarButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 88),
            sidebarButton.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        presentationButton = Theme.button("play.rectangle", label: "Enter presentation mode (⌘⇧P)", target: self, action: #selector(togglePresentation), title: "Present", width: 92)
        previewButton = Theme.button("", label: "Preview Markdown (⌘⇧M)", target: self, action: #selector(toggleMarkdownPreview), title: "Preview", width: 76)
        let documentActions = NSStackView(views: [previewButton, presentationButton]); documentActions.spacing = 8
        scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.drawsBackground = false; editor.textColor = Theme.text; editor.insertionPointColor = Theme.mint
        editor.selectedTextAttributes = [.backgroundColor: Theme.mint.withAlphaComponent(0.22), .foregroundColor: Theme.text]
        editor.textContainerInset = NSSize(width: 40, height: 24)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; editor.setAccessibilityLabel("Note editor")
        editor.registerForDraggedTypes([.fileURL])
        editor.onFileDrop = { [weak self] urls in self?.openDroppedFiles(urls) }
        editor.onEmbedPaste = { [weak self] snippet in self?.insertEmbed(snippet) }
        mediaView.onFileDrop = { [weak self] urls in self?.openDroppedFiles(urls) }
        markdownPreview.onFileDrop = { [weak self] urls in self?.openDroppedFiles(urls) }
        mediaView.onChange = { [weak self] source in
            guard let self, let index = self.index else { return }
            var note = self.notes[index]
            note.text = source; note.modified = Date(); note.dirty = true
            self.notes[index] = note
            self.loading = true; self.editor.string = source; self.loading = false
            self.updateHeader(); self.scheduleRecovery(); self.reloadShelf()
        }
        updateFont()
        language.addItems(withTitles: ["Plain Text", "Markdown", "JavaScript", "TypeScript", "JSON", "YAML", "Environment", "Shell", "Python", "Swift", "CSS", "HTML", "Configuration"])
        language.isBordered = false; language.font = .systemFont(ofSize: 11); language.target = self; language.action = #selector(changeLanguage)
        language.setAccessibilityLabel("Syntax language")
        smallerButton = Theme.button("minus", label: "Smaller text (⌘−)", target: self, action: #selector(smaller))
        largerButton = Theme.button("plus", label: "Larger text (⌘+)", target: self, action: #selector(larger))
        sizeLabel.alignment = .center
        sizeLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let textSizeControls = NSStackView(views: [smallerButton, sizeLabel, largerButton]); textSizeControls.spacing = 0
        let footer = NSStackView(views: [status, NSView(), position, language, textSizeControls]); footer.spacing = 12
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        position.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = Surface(Theme.muted.withAlphaComponent(0.15))
        for view in [titleStack, documentActions, scroll, line, footer] { view.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(view) }
        headerInset = titleStack.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 48)
        footerInset = footer.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 40)
        footerTrailing = footer.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -40)
        dividerInset = line.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 40)
        dividerTrailing = line.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -40)
        NSLayoutConstraint.activate([
            titleStack.topAnchor.constraint(equalTo: main.topAnchor, constant: 56), headerInset, titleStack.trailingAnchor.constraint(lessThanOrEqualTo: documentActions.leadingAnchor, constant: -24),
            documentActions.centerYAnchor.constraint(equalTo: titleStack.centerYAnchor), documentActions.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 24), scroll.leadingAnchor.constraint(equalTo: main.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: main.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1), dividerInset, dividerTrailing, line.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footerInset, footerTrailing, footer.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -20), footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        markdownPreview.onTaskToggle = { [weak self] source, range, replacement in
            guard let self, self.previewing, self.editor.string == source else { return false }
            self.editor.insertText(replacement, replacementRange: range)
            return self.editor.string == (source as NSString).replacingCharacters(in: range, with: replacement)
        }
        markdownPreview.translatesAutoresizingMaskIntoConstraints = false
        markdownPreview.isHidden = true
        main.addSubview(markdownPreview)
        NSLayoutConstraint.activate([
            markdownPreview.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            markdownPreview.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            markdownPreview.topAnchor.constraint(equalTo: scroll.topAnchor),
            markdownPreview.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ])
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        mediaView.isHidden = true
        main.addSubview(mediaView)
        NSLayoutConstraint.activate([
            mediaView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            mediaView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            mediaView.topAnchor.constraint(equalTo: scroll.topAnchor),
            mediaView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    func reloadShelf() {
        reloadingShelf = true
        table.reloadData()
        if let index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        reloadingShelf = false
    }
    private static let noteDragType = NSPasteboard.PasteboardType("dev.luna.note")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard notes.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(notes[row].id.uuidString, forType: Self.noteDragType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if !FileDrop.urls(in: info.draggingPasteboard).isEmpty {
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }
        guard info.draggingSource as? NSTableView === table, (0...notes.count).contains(row) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let files = FileDrop.urls(in: info.draggingPasteboard)
        if !files.isEmpty { openDroppedFiles(files); return true }
        guard info.draggingSource as? NSTableView === table,
              let value = info.draggingPasteboard.string(forType: Self.noteDragType),
              let id = UUID(uuidString: value) else { return false }
        return moveNote(id, to: row)
    }
    @discardableResult func moveNote(_ id: UUID, to row: Int) -> Bool {
        guard let source = notes.firstIndex(where: { $0.id == id }), (0...notes.count).contains(row) else { return false }
        var reordered = notes
        let note = reordered.remove(at: source)
        reordered.insert(note, at: row > source ? row - 1 : row)
        reordered = reordered.filter(\.isPinned) + reordered.filter { !$0.isPinned }
        do { try diskQueue.sync { try store.saveOrder(reordered.map(\.id)) } }
        catch { showError(error); return false }
        notes = reordered
        reloadShelf()
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NoteRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = notes[row]
        let cell = NoteCellView()
        cell.toolTip = note.path ?? note.title
        let title = Theme.label((note.isPinned ? "📌 " : "") + note.title, size: 13, color: Theme.text, weight: .medium)
        let edited = Theme.label(note.path != nil && note.dirty ? "●" : "", size: 8, color: Theme.mint)
        edited.setAccessibilityLabel(note.path != nil && note.dirty ? "Unsaved changes" : "")
        let actions = cell.actionsButton
        actions.isHidden = table.hoveredRow != row
        actions.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Note actions")
        actions.imagePosition = .imageOnly; actions.isBordered = false
        actions.toolTip = "Note actions"; actions.setAccessibilityLabel("Actions for \(note.title)")
        actions.identifier = NSUserInterfaceItemIdentifier(note.id.uuidString)
        actions.target = self; actions.action = #selector(showNoteActions(_:))
        for view in [title, edited, actions] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: edited.leadingAnchor, constant: -8),
            edited.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -4),
            edited.centerYAnchor.constraint(equalTo: cell.centerYAnchor), edited.widthAnchor.constraint(equalToConstant: 8),
            actions.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            actions.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            actions.widthAnchor.constraint(equalToConstant: 28), actions.heightAnchor.constraint(equalToConstant: 28)
        ])
        return cell
    }

    func makeNoteActionsMenu() -> NSMenu {
        let menu = NSMenu()
        let actions: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Pin", #selector(pinClickedNote), "p", [.command, .control]),
            ("Duplicate", #selector(duplicateClickedNote), "d", .command),
            ("Share…", #selector(shareClickedNote), "s", [.command, .control]),
            ("Open in New Window", #selector(openClickedNoteInWindow), "o", [.command, .shift]),
            ("Delete Note…", #selector(deleteClickedNote), "\u{8}", .command)
        ]
        for (title, action, key, modifiers) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showNoteActions(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        actionNoteID = id
        let menu = makeNoteActionsMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 2), in: sender)
        actionNoteID = nil
        sender.isHidden = false
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingShelf else { return }
        guard table.selectedRow >= 0, table.selectedRow < notes.count else { return }
        let id = notes[table.selectedRow].id
        if id != selectedID { select(id) }
    }
    func select(_ id: UUID, focusContent: Bool = false) {
        guard flushRecovery() else { return }
        previewing = false
        selectedID = id
        guard let index else { return }
        richEditing = NoteEmbeds.hasContent(notes[index].text)
        loading = true; editor.string = notes[index].text; editor.undoManager?.removeAllActions(); loading = false
        language.selectItem(withTitle: notes[index].language); highlighter.configure(notes[index].language)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.scrollToBeginningOfDocument(nil)
        updateHeader(); updateFont(); viewportChanged()
        if focusContent || sidebar.isHidden { self.focusContent() }
        else { window?.makeFirstResponder(table) }
        refreshCleanFile(id)
    }
    func refreshCleanFile(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }), !note.dirty, let path = note.path else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let url = URL(fileURLWithPath: path)
                var fresh = try TextFile.read(url)
                if !note.media.isEmpty, fresh.diskModified == note.diskModified { return note }
                fresh.id = id
                guard let self else { return fresh }
                return try self.diskQueue.sync { try self.store.recoverExportedMedia(fresh, from: url) }
            }
            DispatchQueue.main.async {
                guard let self, let index = self.notes.firstIndex(where: { $0.id == id }), !self.notes[index].dirty else { return }
                switch result {
                case .success(var fresh):
                    fresh.id = id
                    fresh.isPinned = self.notes[index].isPinned
                    guard fresh.text != self.notes[index].text || fresh.diskModified != self.notes[index].diskModified else { return }
                    self.notes[index] = fresh
                    if self.selectedID == id {
                        self.loading = true; self.editor.string = fresh.text; self.loading = false
                        self.editor.undoManager?.removeAllActions(); self.updateFont(); self.updateHeader(); self.persistCurrent()
                    }
                case .failure:
                    if self.selectedID == id { self.status.stringValue = "Original unavailable · recovery copy open" }
                }
            }
        }
    }
    func updateHeader() {
        guard let index else { return }; let note = notes[index]
        updatePreview()
        heading.stringValue = note.title
        heading.toolTip = note.title
        subtitle.toolTip = presenting ? nil : note.path
        subtitle.stringValue = presenting ? "Presentation · a little room for the big picture" : (note.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Private note · kept on this Mac")
        notePath.show(path: presenting ? nil : note.path)
        subtitle.isHidden = !presenting && note.path != nil
        updated.stringValue = "Updated " + note.modified.formatted(date: .abbreviated, time: .shortened)
        window?.title = "\(note.title) — Luna"; window?.representedURL = presenting ? nil : note.path.map { URL(fileURLWithPath: $0) }
        window?.isDocumentEdited = note.path != nil && note.dirty
        status.stringValue = note.path == nil ? "●  Kept on this Mac" : (note.dirty ? "●  Edited · ⌘S to save file" : "Saved to file")
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
    }
    func textDidChange(_ notification: Notification) {
        guard !loading, let index else { return }
        notes[index].text = editor.string; notes[index].modified = Date(); notes[index].dirty = true
        updateHeader(); scheduleRecovery(); viewportChanged()
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        // Avoid an O(file size) line count on every keystroke in large files.
        if richEditing { position.stringValue = "Media note"; return }
        if previewing { position.stringValue = "Preview"; return }
        let location = editor.selectedRange().location
        if location > 200_000 { position.stringValue = "Position \(location.formatted())"; return }
        let prefix = (editor.string as NSString).substring(to: min(location, (editor.string as NSString).length))
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let column = (prefix.split(separator: "\n", omittingEmptySubsequences: false).last?.count ?? 0) + 1
        position.stringValue = "Ln \(line), Col \(column)"
    }
    func scheduleRecovery() {
        recoveryTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.persistCurrent() }
        recoveryTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
        status.stringValue = "Keeping your changes…"
    }
    func persistCurrent() {
        guard let index else { return }; let note = notes[index]
        let order = notes.map(\.id)
        diskQueue.async { [weak self] in
            guard let self else { return }
            do { try self.store.save(note); try self.store.saveOrder(order); DispatchQueue.main.async { self.lastRecoveryError = nil; self.updateHeader() } }
            catch { DispatchQueue.main.async { self.lastRecoveryError = error; self.status.stringValue = "Recovery failed — use Save As"; self.showError(error) } }
        }
    }
    @discardableResult func flushRecovery() -> Bool {
        recoveryTask?.cancel()
        guard let index else { return true }
        do { try diskQueue.sync { try store.save(notes[index]); try store.saveOrder(notes.map(\.id)) }; lastRecoveryError = nil; return true }
        catch { lastRecoveryError = error; showError(error); return false }
    }
    @objc func viewportChanged() {
        highlightTask?.cancel()
        let task = DispatchWorkItem { [weak self] in guard let self else { return }; self.highlighter.highlight(self.editor) }
        highlightTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: task)
    }
    func updateFont() {
        let size = displayedFontSize
        editor.font = EditorPreferences.font(at: size)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = size * EditorPreferences.lineSpacing
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: editor.font!]).width * CGFloat(EditorPreferences.tabWidth)
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: editor.font!, .foregroundColor: Theme.text, .paragraphStyle: paragraph]
        if let storage = editor.textStorage { storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length)) }
        updatePreview()
        sizeLabel.stringValue = "\(Int(size)) pt"
        smallerButton?.isEnabled = size > minimumDisplayedSize
        largerButton?.isEnabled = size < maximumDisplayedSize
        viewportChanged()
    }
    @objc func newNote() { guard flushRecovery() else { return }; let note = Note(); notes.insert(note, at: 0); reloadShelf(); select(note.id, focusContent: true); persistCurrent(); showWindow(nil) }
    func insertEmbed(_ snippet: String) {
        editor.insertText(snippet, replacementRange: editor.selectedRange())
        richEditing = true; updatePreview(); focusContent()
    }
    func importMedia(_ urls: [URL], range: NSRange? = nil) {
        guard let id = selectedID else { return }
        let sourceRange = range ?? editor.selectedRange()
        let fromLiveView = richEditing
        status.stringValue = "Adding media…"
        session.pendingMediaImports += 1
        diskQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.store.importMedia(urls, noteID: id) }
            DispatchQueue.main.async {
                defer { self.session.pendingMediaImports -= 1 }
                switch result {
                case .failure(let error): self.updateHeader(); self.showError(error)
                case .success(let media):
                    guard let row = self.notes.firstIndex(where: { $0.id == id }) else { return }
                    self.notes[row].attachments = self.notes[row].media + media
                    let snippet = "\n" + media.map { "![\($0.filename.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))](\($0.reference))" }.joined(separator: "\n\n") + "\n"
                    if self.selectedID == id, fromLiveView, self.richEditing {
                        self.mediaView.insertSnippet(snippet)
                    } else if self.selectedID == id {
                        let length = (self.editor.string as NSString).length
                        let insertion = min(sourceRange.location, length)
                        self.editor.insertText(snippet, replacementRange: NSRange(location: insertion, length: min(sourceRange.length, length - insertion)))
                        self.richEditing = true; self.updatePreview(); self.focusContent()
                    } else {
                        var note = self.notes[row]; note.text += snippet; note.modified = Date(); note.dirty = true
                        self.notes[row] = note
                        self.diskQueue.async { try? self.store.save(note) }
                    }
                    self.persistCurrent()
                }
            }
        }
    }
    func openDroppedFiles(_ urls: [URL]) {
        urls.filter(\.isFileURL).forEach { open($0) }
    }

    @objc func openFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window!) { [weak self] response in if response == .OK { panel.urls.forEach { self?.open($0) } } }
    }
    func open(_ url: URL) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = notes.first(where: { $0.path == url.path }) { select(existing.id); showWindow(nil); return }
        status.stringValue = "Opening \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let note = try TextFile.read(url)
                guard let self else { return note }
                return try self.diskQueue.sync { try self.store.recoverExportedMedia(note, from: url) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let note):
                    if let existing = self.notes.first(where: { $0.path == url.path }) { self.select(existing.id); return }
                    self.notes.insert(note, at: 0); self.reloadShelf(); self.select(note.id); self.persistCurrent(); self.showWindow(nil)
                case .failure(let error): self.updateHeader(); self.showError(error)
                }
            }
        }
    }
    @objc func save() {
        guard let index else { return }
        guard let path = notes[index].path else { saveAs(); return }
        let url = URL(fileURLWithPath: path)
        let currentDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if currentDate != notes[index].diskModified {
            let alert = NSAlert(); alert.messageText = "This file changed outside Luna."
            alert.informativeText = "Save a copy to keep both versions, or replace the version on disk. Your edits are still in Luna’s recovery store."
            alert.addButton(withTitle: "Save a Copy…"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace File")
            let result = alert.runModal()
            if result == .alertFirstButtonReturn { saveAs(); return }
            if result != .alertThirdButtonReturn { return }
        }
        writeCurrent(to: url)
    }
    @objc func saveAs() {
        guard let index else { return }; let id = notes[index].id
        let panel = NSSavePanel(); panel.nameFieldStringValue = notes[index].path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled.txt"
        if !notes[index].media.isEmpty { panel.nameFieldStringValue = "Untitled.md" }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { [weak self] result in
            guard let self, result == .OK, let url = panel.url, self.selectedID == id else { return }
            self.writeCurrent(to: url)
        }
    }
    func writeCurrent(to url: URL) {
        guard let index else { return }
        do {
            try diskQueue.sync { try store.export(notes[index], to: url) }
            notes[index].path = url.path; notes[index].dirty = false
            notes[index].diskModified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            notes[index].language = Note.language(for: url); language.selectItem(withTitle: notes[index].language)
            highlighter.configure(notes[index].language); flushRecovery(); reloadShelf(); updateHeader(); viewportChanged()
        } catch { showError(error) }
    }
    @objc func applyPreferences() {
        editor.currencyPreferencesChanged()
        NSApp.appearance = EditorPreferences.nsAppearance
        window?.appearance = EditorPreferences.nsAppearance
        windowFrost.applyAppearance()
        effects.configurePreferences()
        fontSize = EditorPreferences.fontSize
        table.rowHeight = EditorPreferences.compact ? Theme.Layout.compactRowHeight : Theme.Layout.rowHeight
        editor.isContinuousSpellCheckingEnabled = EditorPreferences.spellChecking
        applyWrapping()
        editor.textColor = Theme.text
        updateLayout(); updateFont(); reloadShelf()
    }
    func updateLayout() {
        let inset = presenting ? max(56, EditorPreferences.editorPadding) : EditorPreferences.editorPadding
        headerInset.constant = inset
        footerInset.constant = inset; footerTrailing.constant = -inset
        dividerInset.constant = inset; dividerTrailing.constant = -inset
        sidebar.isHidden = presenting || !notesVisible
        sidebarWidth.constant = sidebar.isHidden ? 0 : Theme.Layout.sidebarWidth
        if sidebar.isHidden, window?.firstResponder === table { focusContent() }
        sidebarButton.state = sidebar.isHidden ? .off : .on
        let sidebarHelp = sidebar.isHidden ? "Show notes (⌘⌥S)" : "Hide notes (⌘⌥S)"
        sidebarButton.toolTip = sidebarHelp; sidebarButton.setAccessibilityLabel(sidebarHelp)
        presentationButton.state = presenting ? .on : .off
        presentationButton.title = presenting ? "Exit" : "Present"
        let presentationHelp = presenting ? "Exit presentation mode (⌘⇧P)" : "Enter presentation mode (⌘⇧P)"
        presentationButton.toolTip = presentationHelp; presentationButton.setAccessibilityLabel(presentationHelp)
        sidebarButton.needsDisplay = true; presentationButton.needsDisplay = true
        editor.textContainerInset = NSSize(width: inset, height: presenting ? 40 : 24)
    }
    private func applyWrapping() {
        let wrap = EditorPreferences.wrapLines || presenting
        scroll.hasHorizontalScroller = !wrap
        editor.isHorizontallyResizable = !wrap
        editor.autoresizingMask = wrap ? [.width] : []
        editor.textContainer?.widthTracksTextView = wrap
        editor.textContainer?.containerSize = NSSize(width: wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if wrap { editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: editor.frame.height)) }
        editor.sizeToFit()
    }
    private func applySkin() {
        skinBackground.configure(library: skins)
        let enabled = skins.configuration.enabled && skins.configuration.selected != nil
        windowFrost.isHidden = enabled
        sidebar.fillOpacity = 0.25
        main.fillOpacity = 0
    }
    @objc func toggleSidebar() {
        if presenting { presenting = false; notesVisible = true } else { notesVisible.toggle() }
        updateLayout(); applyWrapping(); updateFont(); updateHeader()
    }
    @objc func togglePresentation() {
        presenting.toggle(); presentationFontSize = nil; updateLayout(); applyWrapping(); updateFont(); updateHeader()
    }
    @objc func larger() { adjustTextSize(by: 2) }
    @objc func smaller() { adjustTextSize(by: -2) }
    private func adjustTextSize(by delta: CGFloat) {
        let size = min(maximumDisplayedSize, max(minimumDisplayedSize, displayedFontSize + delta))
        if presenting { presentationFontSize = size; updateFont() }
        else { EditorPreferences.fontSize = size }
    }
    @objc func changeLanguage() {
        guard let index else { return }; notes[index].language = language.titleOfSelectedItem ?? "Plain Text"
        highlighter.configure(notes[index].language)
        editor.textStorage?.addAttribute(.foregroundColor, value: Theme.text, range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
        updatePreview(); viewportChanged(); scheduleRecovery(); reloadShelf()
    }
    func focusContent() {
        window?.makeFirstResponder(richEditing ? mediaView : (previewing ? markdownPreview : editor))
    }
    @objc func toggleMarkdownPreview() {
        guard let index else { return }
        if NoteEmbeds.hasContent(notes[index].text) || richEditing { richEditing.toggle(); previewing = false }
        else if notes[index].language == "Markdown" { previewing.toggle() }
        else { return }
        updatePreview()
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        focusContent()
    }
    private func updatePreview() {
        editor.formatsLists = index.map { ["Plain Text", "Markdown"].contains(notes[$0].language) } ?? true
        let isMarkdown = index.map { notes[$0].language == "Markdown" } ?? false
        if !isMarkdown { previewing = false }
        let hasMedia = index.map { NoteEmbeds.hasContent(notes[$0].text) } ?? false
        previewButton?.isHidden = !isMarkdown && !hasMedia && !richEditing
        previewButton?.title = previewing ? "Edit" : "Preview"
        previewButton?.state = previewing ? .on : .off
        let help = previewing ? "Edit Markdown (⌘⇧M)" : "Preview Markdown (⌘⇧M)"
        previewButton?.toolTip = help; previewButton?.setAccessibilityLabel(help)
        if hasMedia || richEditing {
            previewButton?.title = richEditing ? "Source" : "Live View"
            previewButton?.toolTip = richEditing ? "Edit note source (⌘⇧M)" : "Show media and embeds (⌘⇧M)"
            previewButton?.setAccessibilityLabel(previewButton?.toolTip)
        }
        scroll.isHidden = previewing || richEditing
        markdownPreview.isHidden = !previewing || richEditing
        if !richEditing && !mediaView.isHidden { mediaView.suspend() }
        mediaView.isHidden = !richEditing
        if richEditing, let index {
            mediaView.show(notes[index], store: store, fontSize: displayedFontSize, appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        }
        if previewing { markdownPreview.show(editor.string, fontSize: displayedFontSize, appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance) }
    }
    private func receiveNotes() {
        guard isWindowLoaded else { return }
        if index == nil {
            selectedID = nil
            if let first = notes.first { select(first.id) }
        } else if let index, editor.string != notes[index].text {
            let selection = editor.selectedRange()
            loading = true; editor.string = notes[index].text; loading = false
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0))
            language.selectItem(withTitle: notes[index].language)
            highlighter.configure(notes[index].language)
            updateFont()
        }
        if let index {
            language.selectItem(withTitle: notes[index].language)
            highlighter.configure(notes[index].language)
        }
        reloadShelf(); updateHeader()
    }
    private var clickedNoteID: UUID? {
        actionNoteID ?? (notes.indices.contains(table.clickedRow) ? notes[table.clickedRow].id : selectedID)
    }
    @objc func pinClickedNote() { if let id = clickedNoteID { togglePin(id) } }
    func togglePin(_ id: UUID) {
        guard let row = notes.firstIndex(where: { $0.id == id }) else { return }
        var updated = notes[row]; updated.isPinned.toggle()
        do { try diskQueue.sync { try store.save(updated) } }
        catch { showError(error); return }
        notes[row] = updated
        reloadShelf(); flushRecovery()
    }
    @objc func duplicateClickedNote() { if let id = clickedNoteID { duplicateNote(id) } }
    func duplicateNote(_ id: UUID) {
        guard let row = notes.firstIndex(where: { $0.id == id }), flushRecovery() else { return }
        let original = notes[row]
        var copy = Note(text: original.text, language: original.language)
        copy.attachments = original.attachments
        do { try diskQueue.sync { try store.copyAttachments(from: original, to: copy) } }
        catch { showError(error); return }
        notes.insert(copy, at: row + 1)
        reloadShelf(); select(copy.id, focusContent: true); persistCurrent()
    }
    @objc func shareClickedNote() {
        guard let id = clickedNoteID, let note = notes.first(where: { $0.id == id }) else { return }
        let assets = note.media.filter { note.text.contains($0.reference) }
        var sharedText = note.text
        for item in assets { sharedText = sharedText.replacingOccurrences(of: item.reference, with: item.filename) }
        sharingPicker = NSSharingServicePicker(items: [sharedText] + assets.map { store.attachmentURL($0, noteID: note.id) } as [Any])
        let row = notes.firstIndex(where: { $0.id == id }) ?? table.selectedRow
        sharingPicker?.show(relativeTo: table.rect(ofRow: row), of: table, preferredEdge: .maxX)
    }
    @objc func openClickedNoteInWindow() { if let id = clickedNoteID { openNoteInWindow(id) } }
    @discardableResult func openNoteInWindow(_ id: UUID) -> Workspace? {
        guard notes.contains(where: { $0.id == id }), flushRecovery() else { return nil }
        let child = Workspace(store: store, skinLibrary: skins, session: session)
        additionalWindows.append(child)
        child.select(id, focusContent: true)
        child.window?.setFrameAutosaveName("")
        if let origin = window?.frame.origin { child.window?.setFrameOrigin(NSPoint(x: origin.x + 28, y: origin.y - 28)) }
        child.showWindow(nil)
        return child
    }
    @objc func deleteNote() {
        guard let selectedID else { return }
        confirmDeletion(selectedID)
    }
    @objc func deleteClickedNote() {
        guard notes.indices.contains(table.clickedRow) else { return }
        confirmDeletion(notes[table.clickedRow].id)
    }
    private func confirmDeletion(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        if !Self.requiresCloseConfirmation(note) { removeNote(id); return }
        let alert = NSAlert(); alert.messageText = note.path == nil ? "Delete this note?" : "Close this file with unsaved edits?"
        alert.informativeText = note.path == nil
            ? "“\(note.title)” will be deleted from Luna."
            : "Unsaved edits to “\(note.title)” will be removed from Luna. The saved file on disk will remain unchanged."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: note.path == nil ? "Delete" : "Close")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        removeNote(id)
    }
    static func requiresCloseConfirmation(_ note: Note) -> Bool { note.path == nil || note.dirty }
    @discardableResult func removeNote(_ id: UUID) -> Bool {
        guard let removedIndex = notes.firstIndex(where: { $0.id == id }), flushRecovery() else { return false }
        do { try diskQueue.sync { try store.remove(id) } } catch { showError(error); return false }
        let removedSelection = selectedID == id
        var remaining = notes
        remaining.remove(at: removedIndex)
        if removedSelection { selectedID = nil }
        notes = remaining.isEmpty ? [Note()] : remaining
        reloadShelf()
        if removedSelection { select(notes[min(removedIndex, notes.count - 1)].id) }
        return flushRecovery()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if [#selector(pinClickedNote), #selector(duplicateClickedNote), #selector(shareClickedNote), #selector(openClickedNoteInWindow)].contains(item.action) {
            guard let id = clickedNoteID, let note = notes.first(where: { $0.id == id }) else { return false }
            if item.action == #selector(pinClickedNote) { item.title = note.isPinned ? "Unpin" : "Pin" }
            return true
        }
        if item.action == #selector(deleteClickedNote) {
            guard let id = clickedNoteID, let note = notes.first(where: { $0.id == id }) else { return false }
            item.title = note.path == nil ? "Delete Note…" : (note.dirty ? "Close Tab…" : "Close Tab")
            return true
        }
        if item.action == #selector(deleteNote) { return index != nil }
        if item.action == #selector(toggleMarkdownPreview) {
            item.state = previewing ? .on : .off
            return index.map { notes[$0].language == "Markdown" || NoteEmbeds.hasContent(notes[$0].text) || richEditing } ?? false
        }
        if item.action == #selector(togglePresentation) { item.state = presenting ? .on : .off }
        if item.action == #selector(toggleSidebar) { item.state = !sidebar.isHidden ? .on : .off }
        if item.action == #selector(larger) { return displayedFontSize < maximumDisplayedSize }
        if item.action == #selector(smaller) { return displayedFontSize > minimumDisplayedSize }
        return true
    }
    func flushAllRecovery() -> Bool { session.pendingMediaImports == 0 && session.windows.allObjects.allSatisfy { $0.flushRecovery() } }
    override func showWindow(_ sender: Any?) { super.showWindow(sender); updatePreview() }
    func windowWillClose(_ notification: Notification) { mediaView.suspend() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { session.pendingMediaImports == 0 && flushRecovery() }
    func showError(_ error: Error) { NSAlert(error: error).runModal() }
}
