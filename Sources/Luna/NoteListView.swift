import AppKit

final class NoteListView: NSTableView {
    var focusContent: (() -> Void)?
    private var hoverTracking: NSTrackingArea?
    private(set) var hoveredRow = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            for row in [oldValue, hoveredRow] where row >= 0 {
                (view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteCellView)?.actionsButton.isHidden = row != hoveredRow
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        actionsButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }
}
