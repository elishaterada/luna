// Adapted from the user-owned Sora project to keep sibling-app behavior consistent.
import AppKit
import QuartzCore

final class EditorEffectsView: NSView {
    private let ambient = CAGradientLayer()
    private let pulse = CAGradientLayer()
    private var monitor: Any?
    private let impact = TypingImpact()
    private var impactStrength = TypingImpact.defaultStrength
    private var accessibilityObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    private var glow = false, shake = false, sound = false, returnPulse = false
    private let soundPlayer = TypingSoundPlayer()
    private var lastFeedback: TimeInterval = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for gradient in [ambient, pulse] {
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.15, y: 0)
            gradient.endPoint = CGPoint(x: 0.85, y: 0.8)
            gradient.colors = [Theme.mint.withAlphaComponent(0.16).cgColor,
                               Theme.mint.withAlphaComponent(0).cgColor]
            layer?.addSublayer(gradient)
        }
        pulse.opacity = 0
        pulse.startPoint = CGPoint(x: 0.7, y: 1)
        pulse.endPoint = CGPoint(x: 1, y: 0)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self?.impact.stop()
                    self?.pulse.removeAllAnimations()
                }
            }
        }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.window else { return }
                self.impact.stop()
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for gradient in [ambient, pulse] {
                gradient.colors = [Theme.mint.withAlphaComponent(0.16).cgColor,
                                   Theme.mint.withAlphaComponent(0).cgColor]
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ambient.frame = bounds
        pulse.frame = bounds
        CATransaction.commit()
    }

    func configure(glow: Bool, shake: Bool, sound: Bool, returnPulse: Bool, volume: Double, soundProfile: TypingSound, impactStrength: Double) {
        let strength = TypingImpact.normalizedStrength(impactStrength)
        if !shake || self.impactStrength != strength { impact.stop() }
        self.impactStrength = strength
        self.glow = glow; self.shake = shake; self.sound = sound; self.returnPulse = returnPulse
        ambient.isHidden = !glow
        if !glow && !returnPulse { pulse.removeAllAnimations() }
        if sound { soundPlayer.configure(profile: soundProfile, volume: volume) }
        else { soundPlayer.stop() }
        refreshMonitor()
    }

    func configurePreferences() {
        let defaults = UserDefaults.standard
        configure(glow: defaults.bool(forKey: "editor.effects.glow"),
                  shake: defaults.bool(forKey: "editor.effects.shake"),
                  sound: defaults.bool(forKey: "editor.effects.sound"),
                  returnPulse: defaults.bool(forKey: "editor.effects.returnPulse"),
                  volume: defaults.object(forKey: "editor.effects.volume") as? Double ?? 0.15,
                  soundProfile: TypingSound.resolve(defaults.string(forKey: TypingSound.preferenceKey) ?? TypingSound.defaultSound.rawValue),
                  impactStrength: defaults.object(forKey: TypingImpact.strengthKey) as? Double ?? TypingImpact.defaultStrength)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        impact.stop()
        if window == nil { soundPlayer.stop(); pulse.removeAllAnimations() }
        refreshMonitor()
    }

    private func refreshMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil, glow || shake || sound || returnPulse else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.feedback(for: event)
            return event
        }
    }

    private func feedback(for event: NSEvent) {
        guard let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil,
              EditorPreferences.isTypingFeedbackEvent(characters: event.characters,
                  modifiers: event.modifierFlags, isRepeat: event.isARepeat),
              let responder = window.firstResponder as? NSView else { return }
        guard responder is EditorView else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn || now - lastFeedback >= 0.045 else { return }
        lastFeedback = now
        if sound { soundPlayer.play(isReturn: isReturn) }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if glow || (returnPulse && isReturn) {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = returnPulse && isReturn ? 1 : 0.35
            animation.toValue = 0
            animation.duration = returnPulse && isReturn ? 0.5 : 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulse.add(animation, forKey: "typing")
        }
        if shake, NSEvent.pressedMouseButtons == 0, let content = window.contentView {
            impact.strike(view: content, isReturn: isReturn, strength: impactStrength)
        }
    }

}
