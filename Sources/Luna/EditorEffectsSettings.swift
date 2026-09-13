// Adapted from the user-owned Sora project to keep sibling-app behavior consistent.
import SwiftUI
import AppKit

struct EditorEffectsSettingsSection: View {
    @AppStorage(TypingImpact.strengthKey) private var impactStrength = TypingImpact.defaultStrength
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TypingSound.preferenceKey) private var soundProfile = TypingSound.defaultSound.rawValue
    @StateObject private var soundPreview = TypingSoundPlayer()
    @AppStorage("editor.effects.glow") private var glow = false
    @AppStorage("editor.effects.shake") private var shake = false
    @AppStorage("editor.effects.sound") private var sound = false
    @AppStorage("editor.effects.returnPulse") private var returnPulse = false
    @AppStorage("editor.effects.volume") private var volume = 0.15

    var body: some View {
        Section("Playful effects") {
            Toggle("Ambient glow", isOn: $glow)
            Text("A soft teal glow across the sidebar and editor, with a little light as you type.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Shake window while typing", isOn: $shake)
            Text("Eight varied twists and directional impacts without moving the window. Return hits much harder.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Slider(value: Binding(
                    get: { TypingImpact.normalizedStrength(impactStrength) },
                    set: { impactStrength = $0 }
                ), in: TypingImpact.strengthRange, step: 0.05) { Text("Impact strength") }
                    .accessibilityValue("\(Int((TypingImpact.normalizedStrength(impactStrength) * 100).rounded())) percent")
                Text("\(Int((TypingImpact.normalizedStrength(impactStrength) * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
            HStack {
                ImpactPreviewButton(strength: TypingImpact.normalizedStrength(impactStrength), enabled: !reduceMotion)
                    .fixedSize()
                Button("Reset Strength") { impactStrength = TypingImpact.defaultStrength }
            }
            Text("25% is gentle; 100% is the original strength; 200% is extra punchy. Preview shakes this Settings window’s content.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Typing sounds", isOn: $sound)
            Picker("Keyboard sound", selection: Binding(
                get: { TypingSound.resolve(soundProfile).rawValue },
                set: { soundProfile = $0 }
            )) {
                ForEach(TypingSound.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text(TypingSound.resolve(soundProfile).detail)
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...1) { Text("Typing volume") }
            Button("Preview Sound", systemImage: "speaker.wave.2") {
                soundPreview.configure(profile: TypingSound.resolve(soundProfile), volume: volume)
                soundPreview.play()
            }
            if let error = soundPreview.errorMessage {
                Text(error).font(.caption).foregroundStyle(Color.red)
            }
            Toggle("Return-key light pulse", isOn: $returnPulse)
            Text("All effects are optional. Reduce Motion disables animated light and shake.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Turn Off All Effects") {
                glow = false; shake = false; sound = false; returnPulse = false
                soundPreview.stop()
            }
        }
        .onChange(of: [glow, shake, sound, returnPulse]) { EditorPreferences.notify() }
        .onChange(of: impactStrength) { EditorPreferences.notify() }
        .onChange(of: soundProfile) { EditorPreferences.notify() }
        .onChange(of: volume) { EditorPreferences.notify() }
        .onChange(of: soundProfile) { soundPreview.stop() }
        .onChange(of: volume) { soundPreview.stop() }
        .onDisappear { soundPreview.stop() }
    }
}


/// Explicit preview, scoped to the Settings window rather than a background terminal.
private struct ImpactPreviewButton: NSViewRepresentable {
    let strength: Double
    let enabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Preview Return Impact", target: context.coordinator, action: #selector(Coordinator.preview(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.impact.stop()
        context.coordinator.strength = strength
        button.isEnabled = enabled
        button.toolTip = enabled ? "Preview a strong Return-key impact at this strength" : "Disabled while Reduce Motion is enabled"
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.impact.stop() }
    @MainActor final class Coordinator: NSObject {
        let impact = TypingImpact()
        var strength = TypingImpact.defaultStrength
        @objc func preview(_ sender: NSButton) {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  let view = sender.window?.contentView else { return }
            impact.strike(view: view, isReturn: true, strength: strength)
        }
    }
}
