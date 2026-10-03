import Foundation
import XCTest
@testable import ImrseMac

final class OpenAIChatGPTSignInCoordinatorTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testPreparingCallbackDoesNotLaunchBrowserAndCancellationStopsListener() async throws {
        var openedBrowser = false
        let coordinator = OpenAIChatGPTSignInCoordinator(openBrowser: { _ in
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
    func testInjectedBrowserCanCompleteSyntheticLoopbackCallback() async throws {
        var callbackURL: URL?
        let coordinator = OpenAIChatGPTSignInCoordinator(openBrowser: { authorizationURL in
            guard authorizationURL.host == "auth.openai.com",
                  authorizationURL.path == "/api/accounts/authorize",
                  let callbackURL
            else { return false }
            Task {
                _ = try? await URLSession.shared.data(from: callbackURL)
            }
            return true
        })
        callbackURL = try await coordinator.prepareCallback()
        let authorizationURL = URL(string: "https://auth.openai.com/api/accounts/authorize?client_id=synthetic")!

        let result = try await coordinator.openAndWait(for: authorizationURL, timeout: .seconds(3))

        XCTAssertEqual(result.absoluteString, callbackURL?.absoluteString)
        coordinator.cancel()
    }

    @MainActor
    func testStaleReadyTimeoutCannotFinishNewerLoopbackRun() async throws {
        let timers = ControlledTimeoutSleeper()
        var callbackURL: URL?
        let coordinator = OpenAIChatGPTSignInCoordinator(
            openBrowser: { _ in
                guard let callbackURL else { return false }
                Task { _ = try? await URLSession.shared.data(from: callbackURL) }
                return true
            },
            sleepForTimeout: { duration in
                if duration == .seconds(10) { await timers.sleepIgnoringCancellation() }
                else { try await Task.sleep(for: duration) }
            }
        )

        do {
            _ = try await coordinator.prepareCallback()
            try await waitForCoordinatorCondition { await timers.waiterCount() >= 1 }
            coordinator.cancel()

            let secondCallbackURL = try await coordinator.prepareCallback()
            try await waitForCoordinatorCondition { await timers.waiterCount() >= 2 }
            await timers.releaseFirst()
            callbackURL = secondCallbackURL
            let authorizationURL = URL(string: "https://auth.openai.com/api/accounts/authorize?client_id=synthetic")!
            let result = try await coordinator.openAndWait(for: authorizationURL, timeout: .seconds(3))

            XCTAssertEqual(result.absoluteString, secondCallbackURL.absoluteString)
        } catch {
            coordinator.cancel()
            await timers.releaseAll()
            throw error
        }

        await timers.releaseAll()
        coordinator.cancel()
    }
}

private actor ControlledTimeoutSleeper {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleepIgnoringCancellation() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func waiterCount() -> Int { waiters.count }

    func releaseFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func releaseAll() {
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private func waitForCoordinatorCondition(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CoordinatorTestTimeout()
}

private struct CoordinatorTestTimeout: LocalizedError {
    var errorDescription: String? { "Coordinator timeout task did not reach its test gate." }
}
