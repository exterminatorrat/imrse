#if os(macOS)
import ApplicationServices
import ImrseCore
import Testing
@testable import ImrseMac

struct AccessibilityStatusClassificationTests {
    @Test(arguments: [ImrseError.noSelection, .targetLost, .replacementFailed, .applicationUnreachable])
    func refusedMessagingRequiresPermission(fallback: ImrseError) {
        #expect(AccessibilityStatusClassification.failure(for: .apiDisabled, default: fallback) == .permissionRequired)
    }

    @Test(arguments: [AXError.cannotComplete, .failure, .illegalArgument, .invalidUIElement, .notImplemented])
    func otherStatusesKeepTheCallersFailure(status: AXError) {
        #expect(AccessibilityStatusClassification.failure(for: status, default: .noSelection) == .noSelection)
        #expect(AccessibilityStatusClassification.failure(for: status, default: .applicationUnreachable) == .applicationUnreachable)
    }

    @Test
    func applicationRolePermissionFailureIsNotMissingSelection() {
        #expect(throws: ImrseError.permissionRequired) {
            let _: Int? = try AccessibilityFocusAcquisition.acquire(
                readApplicationRole: { throw AccessibilityStatusClassification.failure(for: .apiDisabled, default: .applicationUnreachable) },
                requestManualAccessibility: {},
                hasTimeForRetry: { false },
                readFocusedElement: { nil },
                validate: { _ in },
                waitBeforeRetry: {}
            )
        }
    }

    @Test
    func manualAccessibilityPermissionFailureIsNotIgnored() {
        #expect(throws: ImrseError.permissionRequired) {
            let _: Int? = try AccessibilityFocusAcquisition.acquire(
                readApplicationRole: {},
                requestManualAccessibility: { throw ImrseError.permissionRequired },
                hasTimeForRetry: { false },
                readFocusedElement: { nil },
                validate: { _ in },
                waitBeforeRetry: {}
            )
        }
    }

    @Test
    func focusedElementPermissionFailureIsNotMissingSelection() {
        #expect(throws: ImrseError.permissionRequired) {
            let _: Int? = try AccessibilityFocusAcquisition.acquire(
                readApplicationRole: {},
                requestManualAccessibility: {},
                hasTimeForRetry: { false },
                readFocusedElement: { throw AccessibilityStatusClassification.failure(for: .apiDisabled, default: .applicationUnreachable) },
                validate: { _ in },
                waitBeforeRetry: {}
            )
        }
    }

    @Test
    func unreachableApplicationRemainsDistinctFromMissingSelection() {
        #expect(throws: ImrseError.applicationUnreachable) {
            let _: Int? = try AccessibilityFocusAcquisition.acquire(
                readApplicationRole: { throw AccessibilityStatusClassification.failure(for: .invalidUIElement, default: .applicationUnreachable) },
                requestManualAccessibility: {},
                hasTimeForRetry: { false },
                readFocusedElement: { nil },
                validate: { _ in },
                waitBeforeRetry: {}
            )
        }
    }

    @Test
    func absentFocusedElementStillReturnsNoSelection() throws {
        let element: Int? = try AccessibilityFocusAcquisition.acquire(
            readApplicationRole: {},
            requestManualAccessibility: {},
            hasTimeForRetry: { false },
            readFocusedElement: { nil },
            validate: { _ in },
            waitBeforeRetry: {}
        )
        #expect(element == nil)
    }
}
#endif
