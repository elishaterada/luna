import AppKit
import XCTest
@testable import Luna

private final class EffectsTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

final class EditorEffectsTests: XCTestCase {
    @MainActor func testAmbientGlowDoesNotFlashWhenTyping() throws {
        _ = NSApplication.shared
        let window = EffectsTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = EditorView(frame: window.contentView!.bounds)
        let effects = EditorEffectsView()
        window.contentView!.addSubview(editor)
        window.contentView!.addSubview(effects)
        window.makeFirstResponder(editor)
        XCTAssertTrue(window.isKeyWindow)
        let pulse = try XCTUnwrap(effects.layer?.sublayers?.last)
        func type(_ characters: String, code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            effects.feedback(for: event)
        }
        effects.configure(glow: true, shake: false, sound: false, returnPulse: false,
                          volume: 0, soundProfile: .defaultSound, impactStrength: 1)
        try type("a", code: 0)
        XCTAssertNil(pulse.animation(forKey: "typing"), "Ambient glow must stay steady while typing")
        try type("\r", code: 36)
        XCTAssertNil(pulse.animation(forKey: "typing"), "Ambient glow alone must not flash on Return")
        effects.configure(glow: true, shake: false, sound: false, returnPulse: true,
                          volume: 0, soundProfile: .defaultSound, impactStrength: 1)
        try type("\r", code: 36)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(pulse.animation(forKey: "typing"))
        }
        effects.configure(glow: true, shake: false, sound: false, returnPulse: false,
                          volume: 0, soundProfile: .defaultSound, impactStrength: 1)
        XCTAssertNil(pulse.animation(forKey: "typing"), "Disabling Return pulse must stop it even with glow on")
    }

    func testTypingFeedbackExcludesShortcutsRepeatsAndNavigation() {
        for text in ["a", "é", "\r", "\u{7f}"] {
            XCTAssertTrue(EditorPreferences.isTypingFeedbackEvent(characters: text, modifiers: [], isRepeat: false))
        }
        XCTAssertFalse(EditorPreferences.isTypingFeedbackEvent(characters: "v", modifiers: .command, isRepeat: false))
        XCTAssertFalse(EditorPreferences.isTypingFeedbackEvent(characters: "c", modifiers: .control, isRepeat: false))
        XCTAssertFalse(EditorPreferences.isTypingFeedbackEvent(characters: "a", modifiers: [], isRepeat: true))
        XCTAssertFalse(EditorPreferences.isTypingFeedbackEvent(characters: "\u{f700}", modifiers: [], isRepeat: false))
        XCTAssertFalse(EditorPreferences.isTypingFeedbackEvent(characters: nil, modifiers: [], isRepeat: false))
    }

    @MainActor func testRecoilSettlesAndStrengthIsBounded() {
        XCTAssertEqual(TypingImpact.normalizedStrength(.nan), 1)
        XCTAssertEqual(TypingImpact.normalizedStrength(20), 2)
        XCTAssertEqual(TypingImpact.normalizedStrength(-1), 0.25)
        for index in TypingImpact.patterns.indices {
            let regular = TypingImpact.poses(isReturn: false, patternIndex: index)
            let enter = TypingImpact.poses(isReturn: true, patternIndex: index)
            XCTAssertEqual(regular.last, TypingImpact.Pose())
            XCTAssertEqual(enter.last, TypingImpact.Pose())
            XCTAssertGreaterThan(enter.map { abs($0.angle) }.max()!, regular.map { abs($0.angle) }.max()!)
            XCTAssertTrue(enter.allSatisfy { $0.angle.isFinite && abs($0.x) <= 8 && abs($0.y) <= 8 })
        }
        var cycle = TypingImpact.PatternCycle()
        XCTAssertEqual(Set((0..<8).map { _ in cycle.next() }).count, 8)
    }

    func testEverySoundProfileProducesDistinctDecodableAudio() {
        var samples = Set<Data>()
        for profile in TypingSound.allCases {
            let data = profile.waveData()
            XCTAssertNotNil(NSSound(data: data))
            XCTAssertNotEqual(data, profile.waveData(isReturn: true))
            samples.insert(data)
        }
        XCTAssertEqual(samples.count, TypingSound.allCases.count)
    }
}
