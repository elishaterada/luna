import AppKit
import LunaCore
import Combine

final class Workspace: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    var notes: [Note] = []
    var selectedID: UUID?
    let store: RecoveryStore
    let diskQueue = DispatchQueue(label: "dev.luna.recovery", qos: .utility)
    var recoveryTask: DispatchWorkItem?
    var highlightTask: DispatchWorkItem?
    let highlighter = SyntaxHighlighter()
    let editor = EditorView(usingTextLayoutManager: true)
    let scroll = NSScrollView()
    let markdownPreview = MarkdownPreview()
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
    let subtitle = Theme.label("Private note · kept on this Mac", size: 11)
    let status = Theme.label("All notes stay with you", size: 11)
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

    init(store: RecoveryStore, skinLibrary: SkinLibrary? = nil) {
        self.store = store
        let skinRoot = ProcessInfo.processInfo.environment["LUNA_RECOVERY_DIR"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("Skins", isDirectory: true)
        }
        skins = skinLibrary ?? skinRoot.map { SkinLibrary(root: $0) } ?? SkinLibrary()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
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
        do { notes = try store.load() } catch { showError(error) }
        if !store.unreadableFiles.isEmpty {
            let alert = NSAlert(); alert.messageText = "Some notes could not be recovered."
            alert.informativeText = "Luna kept the unreadable recovery files untouched in \(store.directory.path). Other notes are available."
            alert.runModal()
        }
        if notes.isEmpty { notes = [Note()] }
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
        let tagline = Theme.label("A little space to think.", size: 12)
        let shelfTitle = Theme.label("Notes", size: 13, weight: .semibold)
        let add = Theme.button("plus", label: "New note (⌘N)", target: self, action: #selector(newNote))
        let shelfHeader = NSStackView(views: [shelfTitle, NSView(), add]); shelfHeader.orientation = .horizontal
        let shelfScroll = NSScrollView(); shelfScroll.drawsBackground = false; shelfScroll.backgroundColor = Theme.panel; shelfScroll.hasVerticalScroller = true; shelfScroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("note")); table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = Theme.Layout.rowHeight; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .plain; table.backgroundColor = .clear; table.selectionHighlightStyle = .regular; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Notes and open files"); shelfScroll.documentView = table
        table.focusContent = { [weak self] in self?.focusContent() }
        let local = Theme.label("Stored on this Mac", size: 11)
        for view in [brand, tagline, shelfHeader, shelfScroll, local] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 56), brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            tagline.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 8), tagline.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            shelfHeader.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 24), shelfHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24), shelfHeader.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -24),
            shelfScroll.topAnchor.constraint(equalTo: shelfHeader.bottomAnchor, constant: 8), shelfScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), shelfScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12), shelfScroll.bottomAnchor.constraint(equalTo: local.topAnchor, constant: -16),
            local.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 28), local.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -24)
        ])
        let titleStack = NSStackView(views: [heading, subtitle]); titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 8
        sidebarButton = Theme.button("sidebar.left", label: "Hide notes (⌘⌥S)", target: self, action: #selector(toggleSidebar))
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarButton)
        NSLayoutConstraint.activate([
            sidebarButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 88),
            sidebarButton.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        presentationButton = Theme.button("play.rectangle", label: "Enter presentation mode (⌘⇧P)", target: self, action: #selector(togglePresentation), title: "Present", width: 92)
        let saveButton = Theme.button("square.and.arrow.down", label: "Save (⌘S)", target: self, action: #selector(save), title: "Save", width: 72)
        saveButton.showsBaseFill = true
        previewButton = Theme.button("", label: "Preview Markdown (⌘⇧M)", target: self, action: #selector(toggleMarkdownPreview), title: "Preview", width: 76)
        let documentActions = NSStackView(views: [previewButton, presentationButton, saveButton]); documentActions.spacing = 8
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
        markdownPreview.translatesAutoresizingMaskIntoConstraints = false
        markdownPreview.isHidden = true
        main.addSubview(markdownPreview)
        NSLayoutConstraint.activate([
            markdownPreview.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            markdownPreview.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            markdownPreview.topAnchor.constraint(equalTo: scroll.topAnchor),
            markdownPreview.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
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
    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NoteRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = notes[row]
        let cell = NSTableCellView()
        cell.toolTip = note.path ?? note.title
        let title = Theme.label(note.title, size: 13, color: Theme.text, weight: .medium)
        let edited = Theme.label(note.path != nil && note.dirty ? "●" : "", size: 8, color: Theme.mint)
        edited.setAccessibilityLabel(note.path != nil && note.dirty ? "Unsaved changes" : "")
        for view in [title, edited] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(equalTo: edited.leadingAnchor, constant: -8),
            edited.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            edited.centerYAnchor.constraint(equalTo: cell.centerYAnchor), edited.widthAnchor.constraint(equalToConstant: 8)
        ])
        return cell
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
            let result = Result { try TextFile.read(URL(fileURLWithPath: path)) }
            DispatchQueue.main.async {
                guard let self, let index = self.notes.firstIndex(where: { $0.id == id }), !self.notes[index].dirty else { return }
                switch result {
                case .success(var fresh):
                    fresh.id = id
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
        diskQueue.async { [weak self] in
            guard let self else { return }
            do { try self.store.save(note); DispatchQueue.main.async { self.lastRecoveryError = nil; self.updateHeader() } }
            catch { DispatchQueue.main.async { self.lastRecoveryError = error; self.status.stringValue = "Recovery failed — use Save As"; self.showError(error) } }
        }
    }
    @discardableResult func flushRecovery() -> Bool {
        recoveryTask?.cancel()
        guard let index else { return true }
        do { try diskQueue.sync { try store.save(notes[index]) }; lastRecoveryError = nil; return true }
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
    @objc func openFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window!) { [weak self] response in if response == .OK { panel.urls.forEach { self?.open($0) } } }
    }
    func open(_ url: URL) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = notes.first(where: { $0.path == url.path }) { select(existing.id); showWindow(nil); return }
        status.stringValue = "Opening \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try TextFile.read(url) }
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
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { [weak self] result in
            guard let self, result == .OK, let url = panel.url, self.selectedID == id else { return }
            self.writeCurrent(to: url)
        }
    }
    func writeCurrent(to url: URL) {
        guard let index else { return }
        do {
            try TextFile.write(notes[index], to: url)
            notes[index].path = url.path; notes[index].dirty = false
            notes[index].diskModified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            notes[index].language = Note.language(for: url); language.selectItem(withTitle: notes[index].language)
            highlighter.configure(notes[index].language); flushRecovery(); reloadShelf(); updateHeader(); viewportChanged()
        } catch { showError(error) }
    }
    @objc func applyPreferences() {
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
        window?.makeFirstResponder(previewing ? markdownPreview : editor)
    }
    @objc func toggleMarkdownPreview() {
        guard let index, notes[index].language == "Markdown" else { return }
        previewing.toggle()
        updatePreview()
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        focusContent()
    }
    private func updatePreview() {
        let isMarkdown = index.map { notes[$0].language == "Markdown" } ?? false
        if !isMarkdown { previewing = false }
        previewButton?.isHidden = !isMarkdown
        previewButton?.title = previewing ? "Edit" : "Preview"
        previewButton?.state = previewing ? .on : .off
        let help = previewing ? "Edit Markdown (⌘⇧M)" : "Preview Markdown (⌘⇧M)"
        previewButton?.toolTip = help; previewButton?.setAccessibilityLabel(help)
        scroll.isHidden = previewing
        markdownPreview.isHidden = !previewing
        if previewing { markdownPreview.show(editor.string, fontSize: displayedFontSize, appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance) }
    }
    @objc func deleteNote() {
        guard let index else { return }
        let alert = NSAlert(); alert.messageText = notes[index].path == nil ? "Delete this note?" : "Remove this file from Luna?"
        alert.informativeText = "The recovery copy will be deleted. Any file saved on disk will remain unchanged."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        recoveryTask?.cancel(); let id = notes[index].id
        do { try diskQueue.sync { try store.remove(id) } } catch { showError(error); return }
        notes.remove(at: index); selectedID = nil
        if notes.isEmpty { notes.append(Note()) }
        reloadShelf(); select(notes[min(index, notes.count - 1)].id)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMarkdownPreview) {
            item.state = previewing ? .on : .off
            return index.map { notes[$0].language == "Markdown" } ?? false
        }
        if item.action == #selector(togglePresentation) { item.state = presenting ? .on : .off }
        if item.action == #selector(toggleSidebar) { item.state = !sidebar.isHidden ? .on : .off }
        if item.action == #selector(larger) { return displayedFontSize < maximumDisplayedSize }
        if item.action == #selector(smaller) { return displayedFontSize > minimumDisplayedSize }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { flushRecovery() }
    func showError(_ error: Error) { NSAlert(error: error).runModal() }
}
