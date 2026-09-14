import AppKit
import LunaCore

let processStarted = ProcessInfo.processInfo.systemUptime

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: Workspace!
    var commandSettings: CommandLineSettings!
    lazy var updates = UpdateController { [weak self] in self?.workspace?.flushAllRecovery() ?? false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory: URL
            if let override = ProcessInfo.processInfo.environment["LUNA_RECOVERY_DIR"] { directory = URL(fileURLWithPath: override) }
            else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Luna/Recovery", isDirectory: true) }
            workspace = Workspace(store: try RecoveryStore(directory: directory))
            let zshDirectory = ProcessInfo.processInfo.environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) }
            commandSettings = CommandLineSettings(integration: CommandLineIntegration(home: FileManager.default.homeDirectoryForCurrentUser, appURL: Bundle.main.bundleURL, zshDirectory: zshDirectory), skins: workspace.skins)
            buildMenu(); workspace.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
            if let report = ProcessInfo.processInfo.environment["LUNA_BENCHMARK_REPORT"] {
                runBenchmark(workspace, started: processStarted, reportPath: report)
                return
            }
            if ProcessInfo.processInfo.environment["LUNA_RECOVERY_DIR"] == nil {
                DispatchQueue.main.async { self.commandSettings.recommendIfNeeded() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updates.start() }
            }
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            for path in args { workspace.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
        } catch { NSAlert(error: error).runModal(); NSApp.terminate(nil) }
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        if workspace == nil {
            DispatchQueue.main.async { [weak self] in urls.forEach { self?.workspace.open($0) } }
        } else { urls.forEach { workspace.open($0) } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { workspace.showWindow(nil); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { workspace == nil || workspace.flushAllRecovery() ? .terminateNow : .terminateCancel }
    @objc func showSettings() { commandSettings.showWindow(nil) }
    @objc func buyMeACoffee() {
        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/elishaterada")!)
    }
    func buildMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; let sub = NSMenu(title: title); item.submenu = sub; menu.addItem(item); return sub }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        let app = submenu("Luna")
        item(app, "About Luna", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        item(app, "Check for Updates…", #selector(UpdateController.checkForUpdates(_:)), target: updates)
        item(app, "Automatically Check for Updates", #selector(UpdateController.toggleAutomaticChecks(_:)), target: updates)
        item(app, "Settings…", #selector(showSettings), ",", target: self)
        item(app, "Buy Me a Coffee", #selector(buyMeACoffee), target: self)
        app.addItem(.separator()); item(app, "Hide Luna", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "Quit Luna", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = submenu("File")
        item(file, "New Note", #selector(Workspace.newNote), "n")
        item(file, "Open…", #selector(Workspace.openFile), "o")
        file.addItem(.separator())
        item(file, "Save", #selector(Workspace.save), "s")
        item(file, "Save As File…", #selector(Workspace.saveAs), "s", [.command, .shift])
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator()); item(file, "Delete Note…", #selector(Workspace.deleteNote), "\u{8}")
        let edit = submenu("Edit")
        item(edit, "Undo", Selector(("undo:")), "z"); item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator()); item(edit, "Cut", #selector(NSText.cut(_:)), "x"); item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v"); item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"); find.tag = NSTextFinder.Action.showFindInterface.rawValue; edit.addItem(find)
        let view = submenu("View")
        item(view, "Toggle Notes", #selector(Workspace.toggleSidebar), "s", [.command, .option])
        item(view, "Markdown Preview", #selector(Workspace.toggleMarkdownPreview), "m", [.command, .shift])
        item(view, "Presentation Mode", #selector(Workspace.togglePresentation), "p", [.command, .shift])
        view.addItem(.separator()); item(view, "Larger Text", #selector(Workspace.larger), "=")
        item(view, "Smaller Text", #selector(Workspace.smaller), "-")
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let window = submenu("Window"); item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window; NSApp.mainMenu = menu
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
