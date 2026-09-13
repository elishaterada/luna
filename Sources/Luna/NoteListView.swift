import AppKit

final class NoteListView: NSTableView {
    var focusContent: (() -> Void)?

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
