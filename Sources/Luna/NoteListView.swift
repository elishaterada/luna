import AppKit

final class NoteListView: NSTableView {
    var showsShortcutHints = false {
        didSet {
            for row in 0..<numberOfRows {
                guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteCellView else { continue }
                cell.showsShortcutHint = showsShortcutHints && row < 9
                cell.actionsButton.isHidden = cell.showsShortcutHint || row != hoveredRow
            }
        }
    }
    var focusContent: (() -> Void)?
    private var hoverTracking: NSTrackingArea?
    private(set) var hoveredRow = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            for row in [oldValue, hoveredRow] where row >= 0 {
                (view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteCellView)?.actionsButton.isHidden = (showsShortcutHints && row < 9) || row != hoveredRow
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }

    override func mouseMoved(with event: NSEvent) { hoveredRow = row(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoveredRow = -1 }

    override func keyDown(with event: NSEvent) {
        // Keep native table navigation and modified arrow shortcuts intact.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 124, modifiers.isEmpty, selectedRow >= 0 {
            focusContent?()
            return
        }
        super.keyDown(with: event)
    }
}

final class NoteCellView: NSTableCellView {
    let actionsButton = NSButton()
    let shortcutLabel = Theme.label("", size: 12)
    var showsShortcutHint = false {
        didSet { shortcutLabel.isHidden = !showsShortcutHint }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        actionsButton.isHidden = true
        shortcutLabel.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }
}
