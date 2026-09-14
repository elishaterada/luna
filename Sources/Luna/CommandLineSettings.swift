import AppKit
import SwiftUI
import LunaCore

final class CommandLineSettings: NSWindowController {
    let defaults: UserDefaults
    private let model: SettingsModel

    init(integration: CommandLineIntegration, skins: SkinLibrary, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = SettingsModel(integration: integration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Luna Settings"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 560)
        window.appearance = EditorPreferences.nsAppearance
        window.contentView = NSHostingView(rootView: LunaSettingsView(model: model, skins: skins))
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: EditorPreferences.changed, object: nil)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func appearanceChanged() { window?.appearance = EditorPreferences.nsAppearance }
    func recommendIfNeeded() {
        guard !defaults.bool(forKey: "commandLineRecommendationSeen") else { return }
        defaults.set(true, forKey: "commandLineRecommendationSeen")
        model.page = .commandLine
        showWindow(nil)
    }
    override func showWindow(_ sender: Any?) {
        model.refresh(); super.showWindow(sender); window?.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case appearance = "Appearance", skins = "Skins", editor = "Editor", commandLine = "Command Line", shortcuts = "Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self { case .appearance: return "circle.lefthalf.filled"; case .skins: return "photo.on.rectangle.angled"; case .editor: return "text.cursor"; case .commandLine: return "terminal"; case .shortcuts: return "keyboard" }
        }
    }
    @Published var page: Page? = .appearance
    @Published var installed = false
    @Published var addToPATH = true
    @Published var message: String?
    @Published var error: String?
    let integration: CommandLineIntegration
    init(integration: CommandLineIntegration) { self.integration = integration; refresh() }
    func refresh() {
        installed = integration.isInstalled
        addToPATH = installed ? integration.managesPATH : true
    }
    func enable() {
        do {
            guard integration.appURL.pathExtension == "app" else {
                throw NSError(domain: "Luna.CommandLine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Open the built Luna.app before enabling its terminal command."])
            }
            try integration.enable(addToZshPATH: addToPATH)
            refresh(); error = nil
            message = addToPATH ? "Command enabled. Open a new terminal tab to use luna." : "Command installed. Add ~/.local/bin to your shell’s PATH to use luna."
        } catch { self.error = error.localizedDescription }
    }
    func disable() {
        do { try integration.disable(); refresh(); error = nil; message = "Command disabled. Your other shell settings are unchanged." }
        catch { self.error = error.localizedDescription }
    }
}

private struct LunaSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var skins: SkinLibrary
    @AppStorage("editor.appearance") private var appearance = "dark"
    @AppStorage("editor.fontFamily") private var family = "SF Mono"
    @AppStorage("editor.fontSize") private var fontSize = 18.0
    @AppStorage("editor.compactSpacing") private var compact = false
    @AppStorage("editor.autoIndent") private var autoIndent = true
    @AppStorage("editor.tabWidth") private var tabWidth = 4

    @AppStorage("editor.lineSpacing") private var lineSpacing = 0.3
    @AppStorage("editor.padding") private var editorPadding = 40.0
    @AppStorage("editor.presentationSize") private var presentationSize = 26.0
    @AppStorage("editor.wrapLines") private var wrapLines = true
    @AppStorage("editor.syntaxColors") private var syntaxColors = true
    @AppStorage("editor.spellChecking") private var spellChecking = false
    @AppStorage("editor.useTabs") private var useTabs = false
    @AppStorage(EditorPreferences.currencyConversionKey) private var currencyConversion = false

    var body: some View {
        NavigationSplitView {
            List(SettingsModel.Page.allCases, selection: $model.page) { page in
                Label(page.rawValue, systemImage: page.icon).padding(.vertical, 6).tag(page)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            if model.page == .skins {
                SkinSettingsView(library: skins)
            } else {
            Form {
                switch model.page ?? .appearance {
                case .appearance:
                    appearanceSections
                    EditorEffectsSettingsSection()
                case .editor: editorSections
                case .commandLine: commandSections
                case .shortcuts: shortcutSections
                case .skins: EmptyView()
                }
            }
            .formStyle(.grouped)
            .scenePadding()
            .navigationTitle((model.page ?? .appearance).rawValue)
            }
        }
        .tint(Color(nsColor: Theme.mint))
        .onChange(of: appearance) { EditorPreferences.notify() }
        .onChange(of: family) { EditorPreferences.notify() }
        .onChange(of: fontSize) { EditorPreferences.notify() }
        .onChange(of: compact) { EditorPreferences.notify() }
        .onChange(of: lineSpacing) { EditorPreferences.notify() }
        .onChange(of: editorPadding) { EditorPreferences.notify() }
        .onChange(of: presentationSize) { EditorPreferences.notify() }
        .onChange(of: wrapLines) { EditorPreferences.notify() }
        .onChange(of: syntaxColors) { EditorPreferences.notify() }
        .onChange(of: spellChecking) { EditorPreferences.notify() }
        .onChange(of: tabWidth) { EditorPreferences.notify() }
        .onChange(of: currencyConversion) { EditorPreferences.notify() }

    }

    @ViewBuilder private var appearanceSections: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            Toggle("Compact spacing", isOn: $compact)
            Text("A tighter notes shelf. Editor margins are set below.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Typography") {
            Picker("Font", selection: $family) {
                ForEach(EditorPreferences.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Slider(value: $fontSize, in: 12...48, step: 1) { Text("Font size") }
                Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
            }
            HStack {
                Slider(value: $lineSpacing, in: 0...1, step: 0.05) { Text("Line spacing") }
                Text("\(Int((lineSpacing * 100).rounded()))%").monospacedDigit().frame(width: 44)
            }
            HStack {
                Slider(value: $editorPadding, in: 16...80, step: 4) { Text("Editor padding") }
                Text("\(Int(editorPadding)) pt").monospacedDigit().frame(width: 44)
            }
            Text("Your next idea.\nlet thought = \"Something good\"")
                .font(Font(EditorPreferences.font(at: fontSize, family: family)))
                .foregroundStyle(Color(nsColor: Theme.text))
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                .padding(20).background(Color(nsColor: Theme.background), in: RoundedRectangle(cornerRadius: 8))
                .lineSpacing(fontSize * lineSpacing)
                .accessibilityLabel("Font preview")
            Button("Restore Appearance Defaults") { EditorPreferences.resetAppearance() }
        }
    }
    @ViewBuilder private var editorSections: some View {
        Section("Currency conversion") {
            Toggle("Enable online currency conversion", isOn: $currencyConversion)
            Text("Off by default. When enabled, currency expressions such as ‘100,000 baht in USD =’ make API requests to Frankfurter, an external exchange-rate service (api.frankfurter.dev).")
                .font(.caption).foregroundStyle(.secondary)
            Text("Only the currency codes are sent—not your amount or note text. Rates are cached for 24 hours and results are approximate. Turn this off to stop currency lookups; ordinary calculations work offline.")
                .font(.caption).foregroundStyle(.secondary)
            Link("About Frankfurter", destination: URL(string: "https://frankfurter.dev/")!)
        }
        Section("Typing") {
            Toggle("Continue indentation on Return", isOn: $autoIndent)
            Toggle("Insert a tab character instead of spaces", isOn: $useTabs)
            Picker("Indent width", selection: $tabWidth) {
                ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
            }
            Toggle("Check spelling while typing", isOn: $spellChecking)
            Text("Quotes and dashes stay exactly as you type them.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Display") {
            Toggle("Wrap long lines", isOn: $wrapLines)
            Toggle("Syntax colors", isOn: $syntaxColors)
            Text("Turn wrapping off to scroll wide code or tables horizontally. Syntax language is chosen in the editor’s status bar.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Notes and files") {
            Label("Notes recover automatically on this Mac", systemImage: "internaldrive")
            Text("Editing a file keeps a recovery copy in Luna. Press ⌘S to save changes to the original file.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Presentation") {
            Text("Presentation mode hides the notes shelf and file path, and uses the minimum text size below. Your preferred text size and sidebar return when you leave.")
            HStack {
                Slider(value: $presentationSize, in: 20...60, step: 2) { Text("Minimum text size") }
                Text("\(Int(presentationSize)) pt").monospacedDigit().frame(width: 44)
            }
            LabeledContent("Toggle presentation", value: "⇧⌘P")
        }
    }
    @ViewBuilder private var commandSections: some View {
        Section("Open from your terminal") {
            Text("luna notes.txt data.csv").font(.system(size: 20, design: .monospaced)).foregroundStyle(Color(nsColor: Theme.mint)).textSelection(.enabled)
            Text("Open any text-based file—notes, CSV data, JSON, Markdown, or source code—from any terminal. Pass one file path or several.").foregroundStyle(.secondary)
            Label(model.installed ? "Command installed" : "Command not installed", systemImage: model.installed ? "checkmark.circle" : "terminal")
        }
        Section("Installation") {
            Toggle("Add to my zsh PATH", isOn: $model.addToPATH)
            Text("Installs ~/.local/bin/luna. This option adds a marked PATH block to \((model.integration.profile.path as NSString).abbreviatingWithTildeInPath). Open a new terminal tab afterward. For other shells, manage PATH yourself.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(model.installed ? "Update Command" : "Enable luna Command") { model.enable() }
                if model.installed { Button("Disable Command") { model.disable() } }
            }
            if let message = model.message { Label(message, systemImage: "checkmark.circle").foregroundStyle(Color(nsColor: Theme.mint)) }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color(nsColor: Theme.pink)).textSelection(.enabled) }
        }
    }
    @ViewBuilder private var shortcutSections: some View {
        Section("Display") {
            Toggle("Wrap long lines", isOn: $wrapLines)
            Toggle("Syntax colors", isOn: $syntaxColors)
            Text("Turn wrapping off to scroll wide code or tables horizontally. Syntax language is chosen in the editor’s status bar.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Notes and files") {
            LabeledContent("New note", value: "⌘N")
            LabeledContent("Open files", value: "⌘O")
            LabeledContent("Save", value: "⌘S")
            LabeledContent("Save as file", value: "⇧⌘S")
            LabeledContent("Find and replace", value: "⌘F")
        }
        Section("Workspace") {
            LabeledContent("Show or hide notes", value: "⌥⌘S")
            LabeledContent("Presentation mode", value: "⇧⌘P")
            LabeledContent("Larger / smaller text", value: "⌘+ / ⌘−")
            LabeledContent("Settings", value: "⌘,")
        }
    }
}
