#if os(macOS)
import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@MainActor
struct ApplicationFocusReturnTests {
    @Test func replacementHandoffWaitsForTheOriginalAndKeepsCheckingCaptureOwnership() async throws {
        let environment = FocusEnvironment()
        environment.makeOriginalFrontmostOnActivation = true
        let token = environment.makeToken()
        var captureChecks = 0
        try await token.restoreForReplacement { captureChecks += 1 }
        #expect(captureChecks >= 2)
        #expect(environment.activationCount == 1)
        #expect(try token.isOriginalFrontmost())
    }

    @Test func replacementHandoffTimesOutWithoutRetryingActivation() async {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        do {
            try await token.restoreForReplacement {}
            Issue.record("An app that never becomes frontmost must time out")
        } catch {
            #expect((error as? ImrseError) == .targetLost)
        }
        #expect(environment.activationCount == 1)
    }

    @Test func cancellationBeforeTheHandoffDoesNotActivateAnything() async {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        let attempt = Task { try await token.restoreForReplacement {} }
        attempt.cancel()
        do {
            try await attempt.value
            Issue.record("A cancelled handoff must fail")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(environment.activationCount == 0)
    }

    @Test func cancellationWhileWaitingDoesNotDispatchAnotherActivation() async {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        let attempt = Task { try await token.restoreForReplacement {} }
        await waitForActivation(environment)
        attempt.cancel()
        do {
            try await attempt.value
            Issue.record("A cancelled handoff must fail")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(environment.activationCount == 1)
    }

    @Test func lostCaptureDuringTheWaitPreventsCompletion() async {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        let attempt = Task {
            try await token.restoreForReplacement {
                guard environment.captureIsCurrent else { throw ImrseError.targetLost }
            }
        }
        await waitForActivation(environment)
        environment.captureIsCurrent = false
        environment.current = environment.original
        do {
            try await attempt.value
            Issue.record("Returning application focus must not revive an invalid capture")
        } catch {
            #expect((error as? ImrseError) == .targetLost)
        }
        #expect(environment.activationCount == 1)
    }

    @Test func thirdAppDuringTheWaitIsNotDisplaced() async {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        let attempt = Task { try await token.restoreForReplacement {} }
        await waitForActivation(environment)
        environment.current = .init(processID: 303, launchDate: environment.date)
        do {
            try await attempt.value
            Issue.record("The handoff must stop when a third app takes focus")
        } catch {
            #expect((error as? ImrseError) == .staleSelection)
        }
        #expect(environment.activationCount == 1)
    }

    @Test func returnIsRequestedOnlyOnceWhileTheOriginalAppIsNotYetFrontmost() throws {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        try token.requestReturn()
        try token.requestReturn()
        token.finishPresentation()
        #expect(environment.activationCount == 1)
        #expect(throws: ImrseError.targetLost) { try token.requestReturn() }
    }

    @Test func originalAlreadyFrontmostDoesNotActivateAnything() throws {
        let environment = FocusEnvironment()
        environment.current = environment.original
        let token = environment.makeToken()
        #expect(try token.isOriginalFrontmost())
        token.finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func presentationCleanupCanReturnFocusWithoutAnySelectionAuthority() {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        token.finishPresentation()
        token.finishPresentation()
        #expect(environment.activationCount == 1)
    }

    @Test func settingsOrNewPresentationInvalidationCannotActivateTheOldApp() {
        let environment = FocusEnvironment()
        let oldToken = environment.makeToken()
        oldToken.invalidate()
        let newToken = environment.makeToken()
        oldToken.finishPresentation()
        #expect(environment.activationCount == 0)
        newToken.finishPresentation()
        #expect(environment.activationCount == 1)
    }

    @Test func thirdApplicationAwayAndBackPermanentlyRevokesTheReturn() {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        token.didActivate(.init(processID: 303, launchDate: environment.date))
        token.didActivate(environment.own)
        token.finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func foregroundThirdApplicationNeverGetsDisplaced() {
        let environment = FocusEnvironment()
        environment.current = .init(processID: 303, launchDate: environment.date)
        environment.makeToken().finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func missingForegroundNeverActivatesTheOriginalApp() {
        let environment = FocusEnvironment()
        environment.current = nil
        environment.makeToken().finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func missingActivationIdentityPermanentlyRevokesTheReturn() {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        token.didActivate(nil)
        token.didActivate(environment.own)
        token.finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func missingLaunchIdentityFailsClosed() {
        let environment = FocusEnvironment()
        environment.makeToken(original: nil).finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func terminatedOriginalApplicationDoesNotActivate() {
        let environment = FocusEnvironment()
        environment.isAlive = false
        environment.makeToken().finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func reusedProcessIDWithDifferentLaunchDateIsNotTheOriginalApp() {
        let environment = FocusEnvironment()
        environment.current = .init(
            processID: environment.original.processID,
            launchDate: environment.date.addingTimeInterval(1)
        )
        environment.makeToken().finishPresentation()
        #expect(environment.activationCount == 0)
    }

    @Test func rejectedActivationIsNeverRetried() {
        let environment = FocusEnvironment()
        environment.activationAccepted = false
        let token = environment.makeToken()
        #expect(throws: ImrseError.targetLost) { try token.requestReturn() }
        token.finishPresentation()
        #expect(environment.activationCount == 1)
    }

    @Test func invalidationAfterAnIssuedRequestDoesNotDispatchAnotherActivation() throws {
        let environment = FocusEnvironment()
        let token = environment.makeToken()
        try token.requestReturn()
        token.invalidate()
        environment.current = environment.original
        #expect(throws: ImrseError.targetLost) { try token.isOriginalFrontmost() }
        token.finishPresentation()
        #expect(environment.activationCount == 1)
    }

    private func waitForActivation(_ environment: FocusEnvironment) async {
        for _ in 0..<10_000 {
            if environment.activationCount > 0 { return }
            await Task.yield()
        }
        Issue.record("Expected activation request was not reached")
    }
}

@MainActor
private final class FocusEnvironment {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var original: ApplicationFocusReturn.Identity { .init(processID: 101, launchDate: date) }
    var own: ApplicationFocusReturn.Identity { .init(processID: 202, launchDate: date) }
    var current: ApplicationFocusReturn.Identity?
    var isAlive = true
    var captureIsCurrent = true
    var activationAccepted = true
    var makeOriginalFrontmostOnActivation = false
    var activationCount = 0

    init() {
        current = own
    }

    func makeToken() -> ApplicationFocusReturn {
        makeToken(original: original)
    }

    func makeToken(original: ApplicationFocusReturn.Identity?) -> ApplicationFocusReturn {
        ApplicationFocusReturn(
            original: original,
            ownProcessID: own.processID,
            originalIsAlive: { self.isAlive },
            foreground: { self.current },
            activateOriginal: {
                self.activationCount += 1
                if self.makeOriginalFrontmostOnActivation { self.current = self.original }
                return self.activationAccepted
            }
        )
    }
}
#endif
