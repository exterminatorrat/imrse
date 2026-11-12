import ApplicationServices
import ImrseCore
import XCTest
@testable import ImrseMac

final class MacSelectionAccessSelectionTests: XCTestCase {
    private typealias SelectionRange = ImrseCore.TextRange

    func testObservedCaptureNotificationsMapOnlyToClosedReasons() {
        XCTAssertEqual(
            ObservedCaptureNotification.failureReason(for: kAXFocusedUIElementChangedNotification as CFString),
            .captureObservedFocusChange
        )
        XCTAssertEqual(
            ObservedCaptureNotification.failureReason(for: kAXSelectedTextChangedNotification as CFString),
            .captureObservedSelectionChange
        )
        XCTAssertEqual(
            ObservedCaptureNotification.failureReason(for: kAXValueChangedNotification as CFString),
            .captureObservedValueChange
        )
        XCTAssertEqual(ObservedCaptureNotification.failureReason(for: "unrecognized" as CFString), .captureInvalidated)
    }

    @MainActor
    func testObservedFocusPreservesCaptureOnlyForSameCurrentElement() {
        let targetID = UUID()

        XCTAssertTrue(ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { 7 },
            sameElement: { $0 == $1 }
        ))
        XCTAssertFalse(ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { 8 },
            sameElement: { $0 == $1 }
        ))
    }

    @MainActor
    func testObservedFocusFailsClosedOnMissingOrUnreadableFocusAndSkipsStaleTarget() {
        let targetID = UUID()
        XCTAssertFalse(ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { nil },
            sameElement: { $0 == $1 }
        ))
        XCTAssertFalse(ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { throw ImrseError.noSelection },
            sameElement: { $0 == $1 }
        ))

        var focusReads = 0
        XCTAssertFalse(ObservedFocusValidation.preservesCapture(
            observedTargetID: UUID(),
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { focusReads += 1; return 7 },
            sameElement: { $0 == $1 }
        ))
        XCTAssertEqual(focusReads, 0)
    }

    @MainActor
    func testWindowContextRefusalSkipsDocumentReadAndMutation() throws {
        let captured = WindowFixture(id: 7, processID: 42, role: "AXWindow")
        let scenarios: [(WindowFixture?, SelectionFailureReason)] = [
            (nil, .windowContextUnavailable),
            (WindowFixture(id: 7, processID: 43, role: "AXWindow"), .windowContextChanged),
            (WindowFixture(id: 8, processID: 42, role: "AXWindow"), .windowContextChanged),
            (WindowFixture(id: 7, processID: 42, role: "AXGroup"), .windowContextChanged)
        ]

        for (current, expectedReason) in scenarios {
            var documentReads = 0
            var mutations = 0
            let reason = try SelectionTargetContextValidation.failureReason(
                capturedWindow: captured,
                capturedDocument: .unavailable,
                currentWindow: current,
                intent: .replaceSelection,
                sameWindow: { $0.id == $1.id },
                isValidWindow: { $0.processID == 42 && $0.role == "AXWindow" },
                readDocument: { _ in documentReads += 1; return .unavailable }
            )

            XCTAssertEqual(reason, expectedReason)
            XCTAssertEqual(documentReads, 0)
            XCTAssertThrowsError(try VerifiedAction.perform(
                verify: {
                    guard reason == nil else { throw ImrseError.staleSelection }
                },
                action: { mutations += 1 }
            )) { error in
                XCTAssertEqual(error as? ImrseError, .staleSelection)
            }
            XCTAssertEqual(mutations, 0)
        }

        let insertionReason = try SelectionTargetContextValidation.failureReason(
            capturedWindow: captured,
            capturedDocument: .unavailable,
            currentWindow: nil,
            intent: .insertAtCaret,
            sameWindow: { $0.id == $1.id },
            isValidWindow: { _ in XCTFail("Missing windows must be rejected first"); return false },
            readDocument: { _ in XCTFail("Missing windows must not read documents"); return .unavailable }
        )
        XCTAssertEqual(insertionReason, .caretProofUnavailable)
    }

    func testValidWindowContextReadsDocumentOnlyAfterIdentityPidAndRolePass() throws {
        let captured = WindowFixture(id: 7, processID: 42, role: "AXWindow")
        var events: [String] = []
        let reason = try SelectionTargetContextValidation.failureReason(
            capturedWindow: captured,
            capturedDocument: .unavailable,
            currentWindow: captured,
            intent: .replaceSelection,
            sameWindow: { $0.id == $1.id },
            isValidWindow: { events.append("window"); return $0.processID == 42 && $0.role == "AXWindow" },
            readDocument: { _ in events.append("document"); return .unavailable }
        )

        XCTAssertNil(reason)
        XCTAssertEqual(events, ["window", "document"])
    }

    func testMissingDocumentVersionOnlyAllowsNilToNil() throws {
        XCTAssertNil(try targetContextFailure())
        XCTAssertEqual(
            try targetContextFailure(capturedDocument: SelectionTargetContextValidation.document("document-A")),
            .documentContextChanged
        )
        XCTAssertEqual(
            try targetContextFailure(currentDocument: SelectionTargetContextValidation.document("document-A")),
            .documentContextChanged
        )
    }

    func testTargetContextRequiresExactDocumentUTF16WhenAvailable() throws {
        XCTAssertNil(try targetContextFailure(
            capturedDocument: SelectionTargetContextValidation.document("document-😀"),
            currentDocument: SelectionTargetContextValidation.document("document-😀")
        ))
        XCTAssertEqual(
            try targetContextFailure(
                capturedDocument: SelectionTargetContextValidation.document("document-A"),
                currentDocument: SelectionTargetContextValidation.document("document-B")
            ),
            .documentContextChanged
        )
        XCTAssertEqual(
            try targetContextFailure(
                capturedDocument: SelectionTargetContextValidation.document("é"),
                currentDocument: SelectionTargetContextValidation.document("e\u{0301}")
            ),
            .documentContextChanged
        )
        XCTAssertEqual(
            try targetContextFailure(currentDocument: .malformed),
            .documentContextUnavailable
        )
    }

    func testDocumentAttributeDecodingHandlesNoValueMalformedValuesAndReadErrors() {
        XCTAssertEqual(
            SelectionTargetContextValidation.documentRead(status: .noValue, value: nil),
            .context(.unavailable)
        )
        XCTAssertEqual(
            SelectionTargetContextValidation.documentRead(status: .noValue, value: "unexpected" as CFString),
            .failed(.documentContextUnavailable)
        )
        XCTAssertEqual(
            SelectionTargetContextValidation.documentRead(status: .success, value: kCFBooleanTrue),
            .failed(.documentContextUnavailable)
        )
        XCTAssertEqual(
            SelectionTargetContextValidation.documentRead(status: .success, value: nil),
            .failed(.documentContextUnavailable)
        )
        XCTAssertEqual(
            SelectionTargetContextValidation.documentRead(status: .success, value: String(
                repeating: "x",
                count: SelectionTargetContextValidation.maximumDocumentUTF16Length + 1
            ) as CFString),
            .failed(.documentContextUnavailable)
        )
        XCTAssertEqual(
            SelectionTargetContextValidation.documentRead(status: .cannotComplete, value: nil),
            .failed(.axReadFailure)
        )
        XCTAssertEqual(
            SelectionTargetContextValidation.documentRead(status: .success, value: "document-😀" as CFString),
            .context(.value(Array("document-😀".utf16)))
        )
    }

    @MainActor
    func testDocumentReadErrorPropagatesBeforeMutationAuthority() {
        let captured = WindowFixture(id: 7, processID: 42, role: "AXWindow")
        var documentReads = 0
        var mutations = 0

        XCTAssertThrowsError(try VerifiedAction.perform(
            verify: {
                _ = try SelectionTargetContextValidation.failureReason(
                    capturedWindow: captured,
                    capturedDocument: .unavailable,
                    currentWindow: captured,
                    intent: .replaceSelection,
                    sameWindow: { (left: WindowFixture, right: WindowFixture) -> Bool in
                        left.id == right.id
                    },
                    isValidWindow: { (window: WindowFixture) -> Bool in
                        window.processID == 42 && window.role == "AXWindow"
                    },
                    readDocument: { (_: WindowFixture) throws -> SelectionTargetContextValidation.Document in
                        documentReads += 1
                        throw TestError.documentReadFailed
                    }
                )
            },
            action: { mutations += 1 }
        )) { error in
            XCTAssertEqual(error as? TestError, .documentReadFailed)
        }

        XCTAssertEqual(documentReads, 1)
        XCTAssertEqual(mutations, 0)
    }

    func testSelectionReadReasonsDistinguishMissingInvalidAndEmptyRanges() {
        XCTAssertEqual(SelectionReadValidation.rangeFailure(nil, allowingEmpty: false), .selectedRangeUnavailable)
        XCTAssertEqual(SelectionReadValidation.rangeFailure(.init(location: -1, length: 1), allowingEmpty: false), .invalidSelectedRange)
        XCTAssertEqual(SelectionReadValidation.rangeFailure(.init(location: Int.max, length: 1), allowingEmpty: false), .invalidSelectedRange)
        XCTAssertEqual(SelectionReadValidation.rangeFailure(.init(location: 0, length: 0), allowingEmpty: false), .emptySelection)
        XCTAssertNil(SelectionReadValidation.rangeFailure(.init(location: 0, length: 0), allowingEmpty: true))
        XCTAssertNil(SelectionReadValidation.rangeFailure(.init(location: 0, length: 2), allowingEmpty: false))
    }

    func testSelectionReadReasonsUseUTF16AndPreserveCollapsedCaretSupport() {
        let range = SelectionRange(location: 0, length: 2)
        XCTAssertEqual(SelectionReadValidation.textFailure(nil, range: range, allowingEmpty: false), .selectedTextUnavailable)
        XCTAssertEqual(SelectionReadValidation.textFailure("", range: range, allowingEmpty: false), .emptySelection)
        XCTAssertEqual(SelectionReadValidation.textFailure("a", range: range, allowingEmpty: false), .selectedTextLengthMismatch)
        XCTAssertNil(SelectionReadValidation.textFailure("😀", range: range, allowingEmpty: false))
        XCTAssertNil(SelectionReadValidation.textFailure("", range: .init(location: 2, length: 0), allowingEmpty: true))
        XCTAssertEqual(SelectionReadValidation.textFailure("a", range: .init(location: 2, length: 0), allowingEmpty: true), .selectedTextLengthMismatch)
    }

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

    func testApplicationRoleIsReadBeforeManualAccessibilityAndFocus() throws {
        var events: [String] = []
        let focused = try AccessibilityFocusAcquisition.acquire(
            readApplicationRole: { events.append("application-role") },
            requestManualAccessibility: { events.append("manual-accessibility") },
            hasTimeForRetry: { false },
            readFocusedElement: { events.append("focus"); return Target(id: 1) },
            validate: { _ in events.append("validate") },
            waitBeforeRetry: { XCTFail("A focused target should not wait") }
        )
        XCTAssertEqual(focused?.id, 1)
        XCTAssertEqual(events, ["application-role", "manual-accessibility", "focus", "validate"])
    }

    func testUnavailableApplicationRoleDoesNotPreventManualAccessibilityOrStrictValidation() throws {
        var manualRequests = 0
        var validations = 0
        XCTAssertThrowsError(try AccessibilityFocusAcquisition.acquire(
            readApplicationRole: { throw ImrseError.noSelection },
            requestManualAccessibility: { manualRequests += 1 },
            hasTimeForRetry: { false },
            readFocusedElement: { Target(id: 1) },
            validate: { _ in validations += 1; throw ImrseError.secureInput },
            waitBeforeRetry: { XCTFail("Protected targets must not retry") }
        )) { XCTAssertEqual($0 as? ImrseError, .secureInput) }
        XCTAssertEqual(manualRequests, 1)
        XCTAssertEqual(validations, 1)
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

    private func targetContextFailure(
        capturedDocument: SelectionTargetContextValidation.Document = .unavailable,
        currentDocument: SelectionTargetContextValidation.Document = .unavailable
    ) throws -> SelectionFailureReason? {
        let window = WindowFixture(id: 7, processID: 42, role: "AXWindow")
        return try SelectionTargetContextValidation.failureReason(
            capturedWindow: window,
            capturedDocument: capturedDocument,
            currentWindow: window,
            intent: .replaceSelection,
            sameWindow: { (left: WindowFixture, right: WindowFixture) -> Bool in
                left.id == right.id
            },
            isValidWindow: { (window: WindowFixture) -> Bool in
                window.processID == 42 && window.role == "AXWindow"
            },
            readDocument: { (_: WindowFixture) -> SelectionTargetContextValidation.Document in currentDocument }
        )
    }

    private struct Target {
        let id: Int
    }

    private struct WindowFixture {
        let id: Int
        let processID: Int32
        let role: String
    }

    private enum TestError: Error, Equatable {
        case focusReadFailed
        case manualAccessibilityRequestFailed
        case staleTarget
        case documentReadFailed
    }
}
