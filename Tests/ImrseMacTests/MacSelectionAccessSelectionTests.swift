import ImrseCore
import XCTest
@testable import ImrseMac

final class MacSelectionAccessSelectionTests: XCTestCase {
    private typealias SelectionRange = ImrseCore.TextRange

    func testFocusAppearingAfterThreeAttemptsIsAcquiredWhileBudgetRemains() throws {
        var events: [String] = []
        var focusReads = 0
        let target = Target(id: 7)

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {
                events.append("manual-accessibility")
            },
            hasTimeForRetry: { true },
            readFocusedElement: {
                events.append("focused-element")
                focusReads += 1
                return focusReads == 4 ? target : nil
            },
            validate: { events.append("validate-\($0.id)") },
            waitBeforeRetry: { events.append("wait") }
        )

        XCTAssertEqual(focusedElement?.id, target.id)
        XCTAssertEqual(events, [
            "manual-accessibility",
            "focused-element",
            "wait",
            "focused-element",
            "wait",
            "focused-element",
            "wait",
            "focused-element",
            "validate-7"
        ])
    }

    func testUnsupportedManualAccessibilityPreservesSingleFocusRead() throws {
        var focusReads = 0
        var waits = 0
        let target = Target(id: 4)

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: { true },
            readFocusedElement: {
                focusReads += 1
                return target
            },
            validate: { _ in },
            waitBeforeRetry: { waits += 1 }
        )

        XCTAssertEqual(focusedElement?.id, target.id)
        XCTAssertEqual(focusReads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testUnsupportedManualAccessibilityRetriesMissingFocusWhileBudgetRemains() throws {
        var focusReads = 0
        var waits = 0
        let target = Target(id: 6)

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: { true },
            readFocusedElement: {
                focusReads += 1
                return focusReads == 2 ? target : nil
            },
            validate: { _ in },
            waitBeforeRetry: { waits += 1 }
        )

        XCTAssertEqual(focusedElement?.id, target.id)
        XCTAssertEqual(focusReads, 2)
        XCTAssertEqual(waits, 1)
    }

    func testManualAccessibilityRequestErrorPreservesBaselineFocus() throws {
        var focusReads = 0
        var waits = 0
        let target = Target(id: 5)

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: { throw TestError.manualAccessibilityRequestFailed },
            hasTimeForRetry: { XCTFail("Failed request should not retry"); return false },
            readFocusedElement: {
                focusReads += 1
                return target
            },
            validate: { _ in },
            waitBeforeRetry: { waits += 1 }
        )

        XCTAssertEqual(focusedElement?.id, target.id)
        XCTAssertEqual(focusReads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testManualAccessibilityRequestFailureRetriesMissingFocusWhileBudgetRemains() throws {
        var focusReads = 0
        var waits = 0
        let target = Target(id: 8)

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: { throw TestError.manualAccessibilityRequestFailed },
            hasTimeForRetry: { true },
            readFocusedElement: {
                focusReads += 1
                return focusReads == 2 ? target : nil
            },
            validate: { _ in },
            waitBeforeRetry: { waits += 1 }
        )

        XCTAssertEqual(focusedElement?.id, target.id)
        XCTAssertEqual(focusReads, 2)
        XCTAssertEqual(waits, 1)
    }

    func testFocusReadErrorIsNotRetried() {
        var focusReads = 0
        var waits = 0

        XCTAssertThrowsError(try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: { true },
            readFocusedElement: { () throws -> Target? in
                focusReads += 1
                throw TestError.focusReadFailed
            },
            validate: { _ in XCTFail("No focused element should be validated") },
            waitBeforeRetry: { waits += 1 }
        )) { error in
            XCTAssertEqual(error as? TestError, .focusReadFailed)
        }

        XCTAssertEqual(focusReads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testFocusRetryStopsOnlyAfterCaptureBudgetRunsOut() throws {
        var focusReads = 0
        var budgetChecks = 0
        var waits = 0

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: {
                budgetChecks += 1
                return budgetChecks <= 8
            },
            readFocusedElement: {
                focusReads += 1
                return nil as Target?
            },
            validate: { _ in XCTFail("No focused element should be validated") },
            waitBeforeRetry: { waits += 1 }
        )

        XCTAssertNil(focusedElement)
        XCTAssertEqual(focusReads, 5)
        XCTAssertGreaterThan(focusReads, 3)
        XCTAssertEqual(waits, 4)
        XCTAssertEqual(budgetChecks, 9)
    }

    func testStaleFocusIsNotReplacedByANewTargetDuringRetry() {
        var focusReads = 0
        var waits = 0

        XCTAssertThrowsError(try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: { true },
            readFocusedElement: {
                focusReads += 1
                return Target(id: focusReads)
            },
            validate: { _ in throw TestError.staleTarget },
            waitBeforeRetry: { waits += 1 }
        )) { error in
            XCTAssertEqual(error as? TestError, .staleTarget)
        }

        XCTAssertEqual(focusReads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testSecureFocusValidationStopsAcquisitionWithoutRetrying() {
        var focusReads = 0
        var waits = 0
        var validations = 0

        XCTAssertThrowsError(try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: { true },
            readFocusedElement: {
                focusReads += 1
                return Target(id: 1)
            },
            validate: { _ in
                validations += 1
                throw ImrseError.secureInput
            },
            waitBeforeRetry: { waits += 1 }
        )) { error in
            XCTAssertEqual(error as? ImrseError, .secureInput)
        }

        XCTAssertEqual(validations, 1)
        XCTAssertEqual(focusReads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testFocusRetryStopsWhenCaptureBudgetExpires() throws {
        var focusReads = 0
        var waits = 0
        var hasTime = true

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: { hasTime },
            readFocusedElement: {
                focusReads += 1
                hasTime = false
                return nil as Target?
            },
            validate: { _ in XCTFail("No focused element should be validated") },
            waitBeforeRetry: { waits += 1 }
        )

        XCTAssertNil(focusedElement)
        XCTAssertEqual(focusReads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testFocusRetryRechecksCaptureBudgetAfterWaiting() throws {
        var focusReads = 0
        var budgetChecks = 0
        var waits = 0

        let focusedElement = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: {},
            hasTimeForRetry: {
                budgetChecks += 1
                return budgetChecks == 1
            },
            readFocusedElement: {
                focusReads += 1
                return nil as Target?
            },
            validate: { _ in XCTFail("No focused element should be validated") },
            waitBeforeRetry: { waits += 1 }
        )

        XCTAssertNil(focusedElement)
        XCTAssertEqual(focusReads, 1)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(budgetChecks, 2)
    }

    func testSelectionLocalRangeTextRecoversMissingOrEmptyDirectText() throws {
        let range = SelectionRange(location: 2, length: 2)

        XCTAssertEqual(try selectedText(directText: nil, range: range, rangeText: "😀"), "😀")
        XCTAssertEqual(try selectedText(directText: "", range: range, rangeText: "😀"), "😀")
    }

    func testNonemptyDirectTextIsNotOverriddenByRangeFallback() throws {
        var rangeReads = 0

        let selectedText = try SelectedTextRangeFallback.resolve(
            directText: "keep",
            range: SelectionRange(location: 0, length: 4),
            failure: .noSelection,
            readStringForRange: {
                rangeReads += 1
                return "else"
            }
        )

        XCTAssertEqual(selectedText, "keep")
        XCTAssertEqual(rangeReads, 0)
    }

    func testNonemptyDirectTextWithUTF16MismatchFailsWithoutUsingRangeFallback() {
        var rangeReads = 0

        XCTAssertThrowsError(try SelectedTextRangeFallback.resolve(
            directText: "wrong",
            range: SelectionRange(location: 1, length: 2),
            failure: .noSelection,
            readStringForRange: {
                rangeReads += 1
                return "😀"
            }
        ))

        XCTAssertEqual(rangeReads, 0)
    }

    func testRejectsRangeFallbackWithDifferentUTF16Length() {
        XCTAssertThrowsError(try selectedText(
            directText: nil,
            range: SelectionRange(location: 0, length: 2),
            rangeText: "x"
        ))
    }

    func testInvalidOrOverLimitRangesFailBeforeReadingRangeText() {
        for range in [
            SelectionRange(location: Int.max, length: 1),
            SelectionRange(location: PlainTextUndoValidation.maximumWholeValueUTF16Length, length: 1)
        ] {
            var rangeReads = 0
            XCTAssertThrowsError(try SelectedTextRangeFallback.resolve(
                directText: nil,
                range: range,
                failure: .noSelection,
                readStringForRange: {
                    rangeReads += 1
                    return "x"
                }
            ))
            XCTAssertEqual(rangeReads, 0)
        }
    }

    func testUnsupportedRangeTextLeavesExistingValueFallbackEligible() throws {
        let range = SelectionRange(location: 0, length: 1)

        XCTAssertNil(try SelectedTextRangeFallback.resolve(
            directText: nil,
            range: range,
            failure: .noSelection,
            readStringForRange: { nil }
        ))
    }

    private func selectedText(directText: String?, range: SelectionRange, rangeText: String?) throws -> String? {
        try SelectedTextRangeFallback.resolve(
            directText: directText,
            range: range,
            failure: .noSelection,
            readStringForRange: { rangeText }
        )
    }

    private struct Target {
        let id: Int
    }

    private enum TestError: Error, Equatable {
        case focusReadFailed
        case manualAccessibilityRequestFailed
        case staleTarget
    }
}
