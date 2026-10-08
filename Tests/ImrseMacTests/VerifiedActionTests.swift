import XCTest
@testable import ImrseMac

final class VerifiedActionTests: XCTestCase {
    @MainActor
    func testRunsActionImmediatelyAfterSuccessfulVerification() throws {
        var events: [String] = []

        let result = try VerifiedAction.perform(
            verify: { events.append("verify") },
            action: {
                events.append("action")
                return 42
            }
        )

        XCTAssertEqual(result, 42)
        XCTAssertEqual(events, ["verify", "action"])
    }

    @MainActor
    func testDoesNotRunActionWhenVerificationThrows() {
        var events: [String] = []

        do {
            _ = try VerifiedAction.perform(
                verify: {
                    events.append("verify")
                    throw Failure.verification
                },
                action: {
                    events.append("action")
                }
            )
            XCTFail("expected verification failure")
        } catch Failure.verification {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(events, ["verify"])
    }

    @MainActor
    func testPropagatesActionFailure() {
        var events: [String] = []

        do {
            try VerifiedAction.perform(
                verify: { events.append("verify") },
                action: {
                    events.append("action")
                    throw Failure.action
                }
            )
            XCTFail("expected action failure")
        } catch Failure.action {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(events, ["verify", "action"])
    }

    private enum Failure: Error {
        case verification
        case action
    }
}
