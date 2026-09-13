import AppKit
import XCTest
@testable import Luna

final class CalculationSuggestionTests: XCTestCase {
    func testPercentagesAndAdjustments() {
        let cases = [
            "$41,000 / $312,000 as % =": "13.14%",
            "20% of $85 =": "$17",
            "$85 + 20% =": "$102",
            "$85 - 20% =": "$68",
            "200 + (5 + 5)% =": "220",
            "50% * 80 =": "40",
            "20% + 5% =": "25%"
        ]
        for (input, expected) in cases { XCTAssertEqual(CalculationSuggestion.result(for: input), expected, input) }
    }

    func testMixedUnitsAndConversions() {
        let cases = [
            "180 cm in feet =": "5 ft 10.87 in",
            "5 ft 8 in in cm =": "172.72 cm",
            "5 ft 8 in + 10 cm in cm =": "182.72 cm",
            "1 km + 250 m =": "1.25 km",
            "2 lb + 8 oz in lb =": "2.5 lb",
            "1 L + 250 ml =": "1.25 L",
            "1h 25m + 45m =": "2h 10m",
            "1h + 30 min in minutes =": "90 min",
            "45m + 1h 25m =": "2h 10m",
            "30 min * 3 =": "1h 30m",
            "2h / 30 min =": "4",
            "1h - 90 min =": "-30m",
            "1h + 0.5s =": "1h 0.5s",
            "2 * (1 km + 500 m) to meters =": "3,000 m"
        ]
        for (input, expected) in cases { XCTAssertEqual(CalculationSuggestion.result(for: input), expected, input) }
        for input in ["1 kg + 1 m =", "1h in kg =", "2 m * 3 m =", "$2 + 3 kg =", "1 kg 2 ft =", "2 m as % =", "1h / 0 min ="] {
            XCTAssertNil(CalculationSuggestion.result(for: input), input)
        }
    }

    func testDateArithmetic() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-13T12:00:00Z"))
        let cases = [
            "Sep 13 + 30 days =": "Oct 13, 2026",
            "2026-12-31 + 1 day =": "Jan 1, 2027",
            "Feb 28, 2024 + 1 day =": "Feb 29, 2024",
            "Jan 31, 2026 + 1 month =": "Feb 28, 2026",
            "Sep 13, 2026 - 2 weeks =": "Aug 30, 2026",
            "today + 1 year =": "Sep 13, 2027"
        ]
        for (input, expected) in cases { XCTAssertEqual(CalculationSuggestion.result(for: input, now: now), expected, input) }
        XCTAssertNil(CalculationSuggestion.result(for: "Feb 30, 2026 + 1 day =", now: now))
    }

    func testNamedValuesAndDerivedReferences() {
        let context = """
        Hourly rate: $150
        Hours: 2080
        Value: Hourly rate x Hours = $1
        Salary: $41,000
        Meeting: 1h 25m
        Walk: 2 km
        """
        XCTAssertEqual(CalculationSuggestion.result(for: "Hourly rate x Hours =", context: context), "$312,000")
        XCTAssertEqual(CalculationSuggestion.result(for: "Ratio: Salary / Value as % =", context: context), "13.14%")
        XCTAssertEqual(CalculationSuggestion.result(for: "Meeting + 45 min =", context: context), "2h 10m")
        XCTAssertEqual(CalculationSuggestion.result(for: "Walk + 500 m =", context: context), "2.5 km")
        XCTAssertEqual(CalculationSuggestion.result(for: "Value =", context: context.replacingOccurrences(of: "$150", with: "$200")), "$416,000")
        XCTAssertNil(CalculationSuggestion.result(for: "HoursExtra + 1 =", context: context))
        XCTAssertNil(CalculationSuggestion.result(for: "Hours + 1 =", context: context + "\nHours: unknown"))
        XCTAssertNil(CalculationSuggestion.result(for: "A + 1 =", context: "A: B\nB: A"))
    }

    @MainActor func testEditorUsesOnlyEarlierDefinitionsAndRefreshesValues() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        editor.string = "Rate: $150\nHours: 2080\nRate x Hours =\nRate: $999"
        let location = (editor.string as NSString).range(of: "=\n").location + 1
        editor.setSelectedRange(NSRange(location: location, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, " $312,000")
        editor.insertText("200", replacementRange: (editor.string as NSString).range(of: "150"))
        editor.setSelectedRange(NSRange(location: location, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, " $416,000")
        editor.insertTab(nil)
        XCTAssertTrue(editor.string.contains("Rate x Hours = $416,000"))
        XCTAssertNotNil(editor.textLayoutManager)
    }

    func testArithmeticAndFormatting() {
        XCTAssertEqual(CalculationSuggestion.result(for: "Workshop Value: $150 x 2080 = "), "$312,000")
        XCTAssertEqual(CalculationSuggestion.result(for: "2 + 3 * 4 ="), "14")
        XCTAssertEqual(CalculationSuggestion.result(for: "(2 + 3) × 4 ="), "20")
        XCTAssertEqual(CalculationSuggestion.result(for: "$41,000 / 2 ="), "$20,500")
        XCTAssertEqual(CalculationSuggestion.result(for: "-10 + 2.5 ="), "-7.5")
        XCTAssertEqual(CalculationSuggestion.result(for: "1 ÷ 3 ="), "0.333333")
    }

    func testIncompleteAndNonArithmeticTextHasNoSuggestion() {
        for line in ["hello =", "123 =", "1 / 0 =", "2 + =", "2 + 3 = 5", "let x =", "abc 2 + 3 =", "1,2 + 3 =", "(2 + 3 =", "2 ** 3 ="] {
            XCTAssertNil(CalculationSuggestion.result(for: line), line)
        }
    }

    @MainActor func testSuggestionAcceptsWithTabAndUndoesAsOneEdit() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        editor.allowsUndo = true
        editor.string = "Workshop Value: $150 x 2080 = "
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, "$312,000")
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "Workshop Value: $150 x 2080 = $312,000")
        XCTAssertNil(editor.calculationSuggestion)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "Workshop Value: $150 x 2080 = ")
    }

    @MainActor func testSelectionLineEndAndDismissal() {
        _ = NSApplication.shared
        let editor = EditorView(usingTextLayoutManager: true)
        editor.string = "😀: 2 + 3 =\nnext"
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, " 5")
        editor.cancelOperation(nil)
        XCTAssertNil(editor.calculationSuggestion)
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertEqual(editor.calculationSuggestion, " 5")
        editor.setSelectedRange(NSRange(location: 10, length: 1))
        XCTAssertNil(editor.calculationSuggestion)
        editor.string = "2 + 3 = more"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertNil(editor.calculationSuggestion)
    }
}
