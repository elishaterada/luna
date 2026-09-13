import AppKit
import LunaCore

final class Workspace: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var notes: [Note] = []
    var selectedID: UUID?
    let store: RecoveryStore
    let diskQueue = DispatchQueue(label: "dev.luna.recovery", qos: .utility)
    var recoveryTask: DispatchWorkItem?
    var highlightTask: DispatchWorkItem?
    let highlighter = SyntaxHighlighter()
    let editor = EditorView(usingTextLayoutManager: true)
    let scroll = NSScrollView()
    let table = NSTableView()
    let sidebar = Surface(Theme.panel)
    let heading = Theme.label("Untitled note", size: 14, color: Theme.text, weight: .medium)
    let subtitle = Theme.label("Private note · kept on this Mac", size: 11)
    let status = Theme.label("All notes stay with you", size: 11)
    let position = Theme.label("Ln 1, Col 1", size: 11)
    let language = NSPopUpButton()
    let sizeLabel = Theme.label("18 pt", size: 11)
    var sidebarWidth: NSLayoutConstraint!
    var fontSize: CGFloat = 18
    var presenting = false
    var loading = false
    var reloadingShelf = false
    var lastRecoveryError: Error?
    var index: Int? { notes.firstIndex { $0.id == selectedID } }

    init(store: RecoveryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Luna"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background; window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 680, height: 420); window.isReleasedWhenClosed = false
        window.delegate = self; window.setFrameAutosaveName("LunaWorkspace"); window.center()
        buildUI()
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
        let main = Surface(Theme.background)
        [sidebar, main].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 224)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebarWidth,
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor), main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let brand = Theme.label("◒  luna", size: 26, color: Theme.mint, weight: .medium)
        let tagline = Theme.label("A little space to think.", size: 11)
        let shelfTitle = Theme.label("YOUR SPACE", size: 10, weight: .semibold)
        let add = Theme.button("plus", label: "New note (⌘N)", target: self, action: #selector(newNote))
        let shelfHeader = NSStackView(views: [shelfTitle, NSView(), add]); shelfHeader.orientation = .horizontal
        let shelfScroll = NSScrollView(); shelfScroll.drawsBackground = true; shelfScroll.backgroundColor = Theme.panel; shelfScroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: .init("note")); table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = 66; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .plain; table.backgroundColor = Theme.panel; table.selectionHighlightStyle = .regular; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Notes and open files"); shelfScroll.documentView = table
        let open = NSButton(title: "Open file…", target: self, action: #selector(openFile)); open.bezelStyle = .rounded
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); open.imagePosition = .imageLeading
        let local = Theme.label("ON YOUR MAC. IN YOUR FLOW.", size: 9)
        for view in [brand, tagline, shelfHeader, shelfScroll, open, local] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 66), brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            tagline.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 6), tagline.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            shelfHeader.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 32), shelfHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24), shelfHeader.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            shelfScroll.topAnchor.constraint(equalTo: shelfHeader.bottomAnchor, constant: 12), shelfScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), shelfScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12), shelfScroll.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -16),
            open.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22), open.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -22), open.bottomAnchor.constraint(equalTo: local.topAnchor, constant: -16),
            local.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24), local.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20)
        ])
        let titleStack = NSStackView(views: [heading, subtitle]); titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 4
        let controls = NSStackView(views: [
            Theme.button("sidebar.left", label: "Toggle notes (⌘⌥S)", target: self, action: #selector(toggleSidebar)),
            Theme.button("minus", label: "Smaller text (⌘−)", target: self, action: #selector(smaller)),
            Theme.button("plus", label: "Larger text (⌘+)", target: self, action: #selector(larger)),
            Theme.button("rectangle.inset.filled", label: "Presentation mode (⌘⇧P)", target: self, action: #selector(togglePresentation)),
            Theme.button("square.and.arrow.down", label: "Save as file (⌘⇧S)", target: self, action: #selector(saveAs))
        ]); controls.spacing = 3
        let controlSurface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(); glass.cornerRadius = 18; glass.contentView = controls; controls.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([controls.centerXAnchor.constraint(equalTo: glass.centerXAnchor), controls.centerYAnchor.constraint(equalTo: glass.centerYAnchor)])
            controlSurface = glass
        } else {
            let effect = NSVisualEffectView(); effect.material = .headerView; effect.wantsLayer = true; effect.layer?.cornerRadius = 18
            effect.addSubview(controls); controls.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6), controls.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6), controls.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4), controls.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4)])
            controlSurface = effect
        }
        scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.drawsBackground = false; editor.textColor = Theme.text; editor.insertionPointColor = Theme.mint
        editor.selectedTextAttributes = [.backgroundColor: Theme.mint.withAlphaComponent(0.22), .foregroundColor: Theme.text]
        editor.textContainerInset = NSSize(width: 48, height: 36)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; editor.setAccessibilityLabel("Note editor")
        updateFont()
        language.addItems(withTitles: ["Plain Text", "Markdown", "JavaScript", "TypeScript", "JSON", "YAML", "Environment", "Shell", "Python", "Swift", "CSS", "HTML", "Configuration"])
        language.isBordered = false; language.font = .systemFont(ofSize: 11); language.target = self; language.action = #selector(changeLanguage)
        language.setAccessibilityLabel("Syntax language")
        let footer = NSStackView(views: [status, NSView(), position, sizeLabel, language]); footer.spacing = 20
        let line = Surface(Theme.muted.withAlphaComponent(0.15))
        for view in [titleStack, controlSurface, scroll, line, footer] { view.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(view) }
        NSLayoutConstraint.activate([
            titleStack.topAnchor.constraint(equalTo: main.topAnchor, constant: 51), titleStack.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 48), titleStack.trailingAnchor.constraint(lessThanOrEqualTo: controlSurface.leadingAnchor, constant: -16),
            controlSurface.centerYAnchor.constraint(equalTo: titleStack.centerYAnchor), controlSurface.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28), controlSurface.widthAnchor.constraint(equalToConstant: 185), controlSurface.heightAnchor.constraint(equalToConstant: 38),
            scroll.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 20), scroll.leadingAnchor.constraint(equalTo: main.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: main.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1), line.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 32), line.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -32), line.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 32), footer.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28), footer.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -12), footer.heightAnchor.constraint(equalToConstant: 22)
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
        let title = Theme.label(note.title, size: 12, color: Theme.text, weight: .medium)
        let detail = Theme.label(note.path == nil ? "Note  ·  \(note.language)" : "File  ·  \(note.language)\(note.dirty ? "  •" : "")", size: 10)
        let icon = NSImageView(image: NSImage(systemSymbolName: note.path == nil ? "note.text" : "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)!)
        icon.contentTintColor = Theme.mint
        for view in [icon, title, detail] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 13), detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5), detail.trailingAnchor.constraint(equalTo: title.trailingAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingShelf else { return }
        guard table.selectedRow >= 0, table.selectedRow < notes.count else { return }
        let id = notes[table.selectedRow].id
        if id != selectedID { select(id) }
    }
    func select(_ id: UUID) {
        guard flushRecovery() else { return }
        selectedID = id
        guard let index else { return }
        loading = true; editor.string = notes[index].text; editor.undoManager?.removeAllActions(); loading = false
        language.selectItem(withTitle: notes[index].language); highlighter.configure(notes[index].language)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.scrollToBeginningOfDocument(nil)
        updateHeader(); updateFont(); viewportChanged(); window?.makeFirstResponder(editor)
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
        heading.stringValue = note.title
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
        let size = presenting ? max(26, fontSize) : fontSize
        editor.font = NSFont(name: "SFMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = size * 0.3
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: editor.font!, .foregroundColor: Theme.text, .paragraphStyle: paragraph]
        if let storage = editor.textStorage { storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length)) }
        sizeLabel.stringValue = "\(Int(size)) pt"; viewportChanged()
    }
    @objc func newNote() { guard flushRecovery() else { return }; let note = Note(); notes.insert(note, at: 0); reloadShelf(); select(note.id); persistCurrent(); showWindow(nil) }
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
    @objc func toggleSidebar() { sidebarWidth.constant = sidebarWidth.constant == 0 ? 224 : 0; sidebar.isHidden = sidebarWidth.constant == 0 }
    @objc func togglePresentation() {
        presenting.toggle(); sidebarWidth.constant = presenting ? 0 : 224; sidebar.isHidden = presenting
        editor.textContainerInset = NSSize(width: presenting ? 72 : 48, height: presenting ? 48 : 36)
        updateFont(); updateHeader()
    }
    @objc func larger() { fontSize = min(48, fontSize + 2); updateFont() }
    @objc func smaller() { fontSize = max(12, fontSize - 2); updateFont() }
    @objc func changeLanguage() {
        guard let index else { return }; notes[index].language = language.titleOfSelectedItem ?? "Plain Text"
        highlighter.configure(notes[index].language)
        editor.textStorage?.addAttribute(.foregroundColor, value: Theme.text, range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
        viewportChanged(); scheduleRecovery(); reloadShelf()
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
    func windowShouldClose(_ sender: NSWindow) -> Bool { flushRecovery() }
    func showError(_ error: Error) { NSAlert(error: error).runModal() }
}
