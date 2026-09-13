import AppKit
import XCTest
@testable import Luna

final class EditorEffectsTests: XCTestCase {
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
