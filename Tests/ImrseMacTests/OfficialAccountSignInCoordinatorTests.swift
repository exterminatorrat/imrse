import Foundation
import XCTest
@testable import ImrseMac

final class OfficialAccountSignInCoordinatorTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testPreparingCallbackStartsLoopbackWithoutOpeningBrowser() async throws {
        var openedBrowser = false
        let coordinator = OfficialAccountSignInCoordinator(openBrowser: { _ in
            openedBrowser = true
            return true
        })

        let callback = try await coordinator.prepareCallback()

        XCTAssertEqual(callback.scheme, "http")
        XCTAssertEqual(callback.host, "127.0.0.1")
        XCTAssertEqual(callback.path, "/auth/callback")
        XCTAssertGreaterThan(callback.port ?? 0, 0)
        XCTAssertFalse(openedBrowser)
        coordinator.cancel()
    }

    @MainActor
    func testLoopbackCallbackReturnsTheURLForAccountServiceValidation() async throws {
        var callbackURL: URL?
        let coordinator = OfficialAccountSignInCoordinator(openBrowser: { authorizationURL in
            guard authorizationURL.host == "openrouter.ai", let callbackURL else { return false }
            Task { _ = try? await URLSession.shared.data(from: callbackURL) }
            return true
        })
        callbackURL = try await coordinator.prepareCallback()

        let result = try await coordinator.openAndWait(
            for: URL(string: "https://openrouter.ai/auth")!,
            timeout: .seconds(3)
        )

        XCTAssertEqual(result.absoluteString, callbackURL?.absoluteString)
        coordinator.cancel()
    }

    @MainActor
    func testAuthorizationAndDeviceURLsAreRestrictedToOfficialOrigins() async throws {
        var openedURLs: [URL] = []
        let coordinator = OfficialAccountSignInCoordinator(openBrowser: { url in
            openedURLs.append(url)
            return true
        })
        _ = try await coordinator.prepareCallback()

        do {
            _ = try await coordinator.openAndWait(
                for: URL(string: "https://attacker.example/auth")!,
                timeout: .seconds(1)
            )
            XCTFail("Untrusted authorization origins must be rejected before opening the browser.")
        } catch {
            XCTAssertTrue(openedURLs.isEmpty)
        }

        XCTAssertTrue(coordinator.openDeviceVerificationPage(for: URL(string: "https://github.com/login/device")!))
        XCTAssertFalse(coordinator.openDeviceVerificationPage(for: URL(string: "https://attacker.example/login/device")!))
        XCTAssertEqual(openedURLs, [URL(string: "https://github.com/login/device")!])
        coordinator.cancel()
    }
}
