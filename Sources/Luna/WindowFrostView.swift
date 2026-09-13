// Adapted from the user-owned Sora project to keep sibling-app behavior consistent.
import AppKit

final class WindowFrostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var material: NSView?
    private var accessibilityObserver: NSObjectProtocol?
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            material = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            material = effect
        }
        if let material { addSubview(material) }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applyAppearance() } }
        applyAppearance()
    }
    deinit { if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) } }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); material?.frame = bounds }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    func applyAppearance() {
        // Accessibility keeps a solid base; otherwise both themes share glass.
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material?.isHidden = solid
        layer?.backgroundColor = (solid ? (EditorPreferences.isLight
            ? NSColor(calibratedWhite: 0.965, alpha: 1)
            : NSColor(calibratedWhite: 0.10, alpha: 1)) : .clear).cgColor
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView { glass.tintColor = NSColor(calibratedWhite: EditorPreferences.isLight ? 0.96 : 0.10, alpha: 0.65) }
    }
}
