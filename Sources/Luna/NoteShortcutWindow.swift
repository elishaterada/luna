import AppKit

/// Keep shortcuts scoped to this workspace, including when its editor or preview has focus.
final class NoteShortcutWindow: NSWindow {
    var deleteSelectedNote: (() -> Void)?
    var selectNoteNumber: ((Int) -> Bool)?
    var showShortcutHints: ((Bool) -> Void)?
    private var hintTimer: Timer?
    private var holdingCommand = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleNoteShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleNoteShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if attachedSheet == nil, modifiers == .command, event.keyCode == 51,
           let deleteSelectedNote {
            deleteSelectedNote()
            return true
        }
        if attachedSheet == nil, modifiers == .command,
           let characters = event.charactersIgnoringModifiers, characters.count == 1,
           let number = Int(characters), (1...9).contains(number),
           selectNoteNumber?(number) == true { return true }
        return false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleNoteShortcut(event) { return }
        if event.type == .flagsChanged {
            updateShortcutModifiers(event.modifierFlags)
        }
        super.sendEvent(event)
    }

    func updateShortcutModifiers(_ flags: NSEvent.ModifierFlags) {
        let commandOnly = flags.intersection([.command, .control, .option, .shift]) == .command
        guard commandOnly != holdingCommand else { return }
        resetShortcutHints()
        guard commandOnly, attachedSheet == nil else { return }
        holdingCommand = true
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            guard let self, self.holdingCommand, self.isKeyWindow, self.attachedSheet == nil else { return }
            self.showShortcutHints?(true)
        }
        hintTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func resetShortcutHints() {
        hintTimer?.invalidate()
        hintTimer = nil
        holdingCommand = false
        showShortcutHints?(false)
    }

    override func resignKey() {
        resetShortcutHints()
        super.resignKey()
    }

    override func close() {
        resetShortcutHints()
        super.close()
    }
}
