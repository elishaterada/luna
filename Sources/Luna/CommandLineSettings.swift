import AppKit
import LunaCore

final class CommandLineSettings: NSWindowController {
    let integration: CommandLineIntegration
    let defaults: UserDefaults
    let state = Theme.label("", size: 12, color: Theme.mint)
    let togglePATH = NSButton(checkboxWithTitle: "Add the command to my zsh PATH (recommended)", target: nil, action: nil)
    let enableButton = NSButton(title: "Enable luna command", target: nil, action: nil)
    let disableButton = NSButton(title: "Disable command", target: nil, action: nil)
    let laterButton = NSButton(title: "Not now", target: nil, action: nil)

    init(integration: CommandLineIntegration, defaults: UserDefaults = .standard) {
        self.integration = integration; self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Luna Settings"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua); window.backgroundColor = Theme.background
        let title = Theme.label("One command. A little space.", size: 24, color: Theme.text, weight: .medium)
        let intro = NSTextField(wrappingLabelWithString: "Open a file straight from your terminal. Enable Luna’s command to make quick edits part of your flow.")
        intro.font = .systemFont(ofSize: 13); intro.textColor = Theme.muted
        let example = Theme.label("luna ~/.zshrc", size: 22, color: Theme.mint)
        example.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        let details = NSTextField(wrappingLabelWithString: "Installs ~/.local/bin/luna. The option below adds a marked PATH block to \((integration.profile.path as NSString).abbreviatingWithTildeInPath). Open a new terminal tab afterward. You can disable it here anytime.")
        details.font = .systemFont(ofSize: 12); details.textColor = Theme.muted
        togglePATH.state = integration.isInstalled ? (integration.managesPATH ? .on : .off) : .on
        togglePATH.font = .systemFont(ofSize: 12)
        enableButton.bezelStyle = .rounded; enableButton.target = self; enableButton.action = #selector(enable)
        enableButton.keyEquivalent = "\r"
        disableButton.bezelStyle = .rounded; disableButton.target = self; disableButton.action = #selector(disable)
        laterButton.bezelStyle = .rounded; laterButton.target = self; laterButton.action = #selector(dismiss)
        let buttons = NSStackView(views: [disableButton, NSView(), laterButton, enableButton]); buttons.spacing = 12
        let stack = NSStackView(views: [title, intro, example, details, togglePATH, state, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor), details.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refresh(); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func recommendIfNeeded() {
        guard !defaults.bool(forKey: "commandLineRecommendationSeen") else { return }
        defaults.set(true, forKey: "commandLineRecommendationSeen")
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    override func showWindow(_ sender: Any?) { refresh(); super.showWindow(sender); window?.makeKeyAndOrderFront(nil) }
    func refresh() {
        let installed = integration.isInstalled
        state.stringValue = installed ? "●  Command installed · luna [filepath]" : "Recommended for quick file edits"
        enableButton.title = installed ? "Update command" : "Enable luna command"
        disableButton.isHidden = !installed; laterButton.title = installed ? "Done" : "Not now"
    }
    @objc func enable() {
        do {
            guard integration.appURL.pathExtension == "app" else {
                throw NSError(domain: "Luna.CommandLine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Open the built Luna.app before enabling its terminal command."])
            }
            try integration.enable(addToZshPATH: togglePATH.state == .on)
            refresh()
            state.stringValue = togglePATH.state == .on ? "●  Enabled — open a new terminal tab to use luna" : "●  Installed — ensure ~/.local/bin is on your shell’s PATH"
        } catch { NSAlert(error: error).beginSheetModal(for: window!) }
    }
    @objc func disable() {
        do { try integration.disable(); refresh(); state.stringValue = "Command disabled. Your other shell settings are unchanged." }
        catch { NSAlert(error: error).beginSheetModal(for: window!) }
    }
    @objc func dismiss() { close() }
}
