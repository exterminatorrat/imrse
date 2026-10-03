#if os(macOS)
import ServiceManagement
import XCTest
@testable import ImrseMac

@MainActor
final class MainAppLoginItemServiceTests: XCTestCase {
    func testMapsSystemStatuses() {
        XCTAssertEqual(MainAppLoginItemStatus(systemStatus: .notFound), .notFound)
        XCTAssertEqual(MainAppLoginItemStatus(systemStatus: .notRegistered), .notRegistered)
        XCTAssertEqual(MainAppLoginItemStatus(systemStatus: .enabled), .enabled)
        XCTAssertEqual(MainAppLoginItemStatus(systemStatus: .requiresApproval), .requiresApproval)
    }

    func testOnlyRegisteredStatesAllowTheMatchingAction() {
        XCTAssertEqual(MainAppLoginItemStatus.notRegistered.action(requesting: true), .register)
        XCTAssertNil(MainAppLoginItemStatus.notRegistered.action(requesting: false))
        XCTAssertEqual(MainAppLoginItemStatus.enabled.action(requesting: false), .unregister)
        XCTAssertNil(MainAppLoginItemStatus.enabled.action(requesting: true))
    }

    func testUnavailableApprovalAndUnknownStatesNeverRequestRegistrationChanges() {
        for status in [MainAppLoginItemStatus.notFound, .requiresApproval, .unknown] {
            XCTAssertNil(status.action(requesting: true))
            XCTAssertNil(status.action(requesting: false))
        }
    }

    func testExplicitRecoveryReturnsTheObservedNativeOutcome() throws {
        for expectedStatus in [MainAppLoginItemStatus.enabled, .requiresApproval, .notRegistered, .notFound, .unknown] {
            var registrationCount = 0
            var statusReadCount = 0
            let recoveredStatus = try MainAppLoginItemService.recoveryResult(
                from: .notFound,
                register: { registrationCount += 1 },
                readStatus: {
                    statusReadCount += 1
                    return expectedStatus
                }
            )

            XCTAssertEqual(registrationCount, 1)
            XCTAssertEqual(statusReadCount, 1)
            XCTAssertEqual(recoveredStatus, expectedStatus)
        }
    }

    func testExplicitRecoveryPreservesApprovalAndUnknownStatesWithoutRegistering() throws {
        for status in [MainAppLoginItemStatus.notRegistered, .enabled, .requiresApproval, .unknown] {
            var registrationCount = 0
            var statusReadCount = 0
            let observedStatus = try MainAppLoginItemService.recoveryResult(
                from: status,
                register: { registrationCount += 1 },
                readStatus: {
                    statusReadCount += 1
                    return .enabled
                }
            )

            XCTAssertEqual(registrationCount, 0)
            XCTAssertEqual(statusReadCount, 0)
            XCTAssertEqual(observedStatus, status)
        }
    }

    func testExplicitRecoveryPropagatesNSErrorAndDoesNotInventAnOutcome() {
        let nativeError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The native registration failed."]
        )
        var statusReadCount = 0

        do {
            _ = try MainAppLoginItemService.recoveryResult(
                from: .notFound,
                register: { throw nativeError },
                readStatus: {
                    statusReadCount += 1
                    return .enabled
                }
            )
            XCTFail("Expected the native registration error to propagate")
        } catch {
            let actualError = error as NSError
            XCTAssertEqual(actualError.domain, nativeError.domain)
            XCTAssertEqual(actualError.code, nativeError.code)
            XCTAssertEqual(actualError.localizedDescription, nativeError.localizedDescription)
        }
        XCTAssertEqual(statusReadCount, 0)
    }
}
#endif
