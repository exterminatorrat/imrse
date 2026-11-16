import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@MainActor
struct ReplacementDispatchStateTests {
    private enum WriteResult: Equatable {
        case rejected
        case applied
    }

    private struct PasteTransaction {
        var mutated = false
    }

    @MainActor
    private final class Probe {
        var invocations = 0
    }

    @MainActor
    private final class PasteFixture {
        let recovery = ClipboardPasteRecovery<PasteTransaction, Int>()
        var posts = 0
        var restores = 0

        func run(confirmError: ImrseError?) async throws -> String {
            try await recovery.perform(
                destination: 1,
                capture: { PasteTransaction() },
                stage: { $0.mutated = true },
                verify: { _ in },
                post: { self.posts += 1 },
                confirm: {
                    if let confirmError { throw confirmError }
                    return "receipt"
                },
                hasMutated: { $0.mutated },
                restore: { _ in
                    self.restores += 1
                    return true
                }
            )
        }
    }

    @Test func preDispatchFailureProvesNoDispatch() throws {
        let dispatch = ReplacementDispatchState()
        let probe = Probe()

        func configure(reject: Bool) throws {
            if reject { throw ImrseError.targetLost }
        }

        do {
            try configure(reject: true)
            _ = try dispatch.perform {
                probe.invocations += 1
                return WriteResult.applied
            }
            Issue.record("configure must fail before the write reaches the action")
        } catch {
            #expect(error as? ImrseError == .targetLost)
        }

        #expect(probe.invocations == 0)
        #expect(dispatch.dispatched == false)
        #expect(
            dispatch.failure(ImrseError.targetLost, invalidatesPriorUndo: false)
                == .notWritten(.targetLost, invalidatesPriorUndo: false)
        )
    }

    @Test func verifyFailureBeforeDispatchProvesNoDispatch() throws {
        let dispatch = ReplacementDispatchState()
        let probe = Probe()

        func verify(reject: Bool) throws {
            if reject { throw ImrseError.staleSelection }
        }

        do {
            try verify(reject: true)
            _ = try dispatch.perform {
                probe.invocations += 1
                return WriteResult.applied
            }
            Issue.record("verify must fail before the action reaches the write")
        } catch {
            #expect(error as? ImrseError == .staleSelection)
        }

        #expect(probe.invocations == 0)
        #expect(dispatch.dispatched == false)
        #expect(
            dispatch.failure(ImrseError.staleSelection, invalidatesPriorUndo: false)
                == .notWritten(.staleSelection, invalidatesPriorUndo: false)
        )
    }

    @Test func rejectedWriteAfterDispatchIsUnconfirmed() throws {
        let dispatch = ReplacementDispatchState()
        let status = try dispatch.perform { WriteResult.rejected }

        #expect(status == .rejected)
        #expect(dispatch.dispatched)
        #expect(
            dispatch.failure(ImrseError.replacementFailed, invalidatesPriorUndo: false)
                == .unconfirmed(.replacementFailed)
        )
    }

    @Test func readbackFailureAfterDispatchIsUnconfirmed() throws {
        let dispatch = ReplacementDispatchState()
        _ = try dispatch.perform { WriteResult.applied }

        #expect(
            dispatch.failure(ImrseError.clipboardPending, invalidatesPriorUndo: false)
                == .unconfirmed(.clipboardPending)
        )
        #expect(
            dispatch.failure(ImrseError.clipboardPending, invalidatesPriorUndo: true)
                == .unconfirmed(.clipboardPending)
        )
    }

    @Test func cancellationBeforeDispatchDoesNotInvokeOrMark() async {
        let dispatch = ReplacementDispatchState()
        let probe = Probe()

        let outcome = await Task<ReplacementOutcome?, Never> { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try dispatch.perform {
                    probe.invocations += 1
                    return WriteResult.applied
                }
                return nil
            } catch {
                return dispatch.failure(error, invalidatesPriorUndo: false)
            }
        }.value

        #expect(probe.invocations == 0)
        #expect(dispatch.dispatched == false)
        #expect(outcome == ReplacementOutcome.notWritten(.cancelled, invalidatesPriorUndo: false))
    }

    @Test func cancellationAfterDispatchRemainsUnconfirmed() throws {
        let dispatch = ReplacementDispatchState()
        _ = try dispatch.perform { WriteResult.applied }

        #expect(dispatch.failure(CancellationError(), invalidatesPriorUndo: true) == .unconfirmed(.cancelled))
    }

    @Test func pastePathMarkAloneForcesUnconfirmed() {
        let dispatch = ReplacementDispatchState()
        let probe = Probe()

        dispatch.markDispatched()

        #expect(probe.invocations == 0)
        #expect(dispatch.dispatched)
        #expect(
            dispatch.failure(ImrseError.clipboardFailed, invalidatesPriorUndo: false)
                == .unconfirmed(.clipboardFailed)
        )
    }

    @Test func dispatchStateIsPerCall() throws {
        let first = ReplacementDispatchState()
        let second = ReplacementDispatchState()

        _ = try first.perform { WriteResult.applied }

        #expect(first.dispatched)
        #expect(second.dispatched == false)
        #expect(
            second.failure(ImrseError.staleSelection, invalidatesPriorUndo: false)
                == .notWritten(.staleSelection, invalidatesPriorUndo: false)
        )
        #expect(
            first.failure(ImrseError.staleSelection, invalidatesPriorUndo: false)
                == .unconfirmed(.staleSelection)
        )
    }

    @Test func provedNoOpFallbackDoesNotResetDispatch() throws {
        let dispatch = ReplacementDispatchState()
        _ = try dispatch.perform { WriteResult.rejected }

        let fallback = SelectionMutationOutcome<WriteResult>.provedNotApplied
        #expect(fallback.allowsFallback)

        #expect(dispatch.dispatched)
        #expect(
            dispatch.failure(ImrseError.replacementFailed, invalidatesPriorUndo: false)
                == .unconfirmed(.replacementFailed)
        )
    }

    @Test func unknownErrorsNormalizeWhileExplicitErrorsSurvive() {
        let dispatch = ReplacementDispatchState()

        #expect(
            dispatch.failure(NSError(domain: "unexpected", code: 1), invalidatesPriorUndo: false)
                == .notWritten(.replacementFailed, invalidatesPriorUndo: false)
        )
        #expect(
            dispatch.failure(ImrseError.permissionRequired, invalidatesPriorUndo: true)
                == .notWritten(.permissionRequired, invalidatesPriorUndo: true)
        )

        dispatch.markDispatched()

        #expect(
            dispatch.failure(NSError(domain: "unexpected", code: 2), invalidatesPriorUndo: false)
                == .unconfirmed(.replacementFailed)
        )
    }

    @Test func priorPendingClipboardBlocksWithoutDispatchAndInvalidatesPriorUndo() async {
        let paste = PasteFixture()

        do {
            _ = try await paste.run(confirmError: .replacementFailed)
            Issue.record("an unconfirmed paste must not return a receipt")
        } catch {
            #expect(error as? ImrseError == .clipboardPending)
        }

        #expect(paste.posts == 1)
        #expect(paste.restores == 0)
        #expect(paste.recovery.isBlocked)

        let dispatch = ReplacementDispatchState()
        let outcome = dispatch.failure(
            ImrseError.clipboardPending,
            invalidatesPriorUndo: paste.recovery.isBlocked
        )

        #expect(outcome == .notWritten(.clipboardPending, invalidatesPriorUndo: true))
        #expect(paste.recovery.isBlocked)

        do {
            _ = try await paste.run(confirmError: nil)
            Issue.record("a blocked recovery must refuse a new paste before dispatch")
        } catch {
            #expect(error as? ImrseError == .clipboardPending)
        }

        #expect(paste.posts == 1)
        #expect(paste.recovery.isBlocked)
    }

    @Test func failedRestorationBeforePostingDoesNotClaimAHostDispatch() async {
        let recovery = ClipboardPasteRecovery<PasteTransaction, Int>()
        let dispatch = ReplacementDispatchState()
        var posts = 0
        var restores = 0
        do {
            let _: String = try await recovery.perform(
                destination: 1,
                capture: { PasteTransaction() },
                stage: { $0.mutated = true },
                verify: { _ in throw ImrseError.staleSelection },
                post: {
                    dispatch.markDispatched()
                    posts += 1
                },
                confirm: { "receipt" },
                hasMutated: { $0.mutated },
                restore: { _ in
                    restores += 1
                    return false
                }
            )
            Issue.record("A failed clipboard restoration must retain recovery")
        } catch {
            #expect(error as? ImrseError == .clipboardPending)
            #expect(dispatch.failure(error, invalidatesPriorUndo: recovery.isBlocked)
                == .notWritten(.clipboardPending, invalidatesPriorUndo: true))
        }
        #expect(posts == 0)
        #expect(restores == 1)
        #expect(recovery.isBlocked)
        #expect(!dispatch.dispatched)
    }

    @Test func cancellationAfterAnEarlierAttemptPreventsANewDispatchWithoutErasingUncertainty() async {
        let dispatch = ReplacementDispatchState()
        let probe = Probe()
        let outcome = await Task<ReplacementOutcome?, Never> { @MainActor in
            do {
                _ = try dispatch.perform {
                    probe.invocations += 1
                    return WriteResult.applied
                }
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try dispatch.perform {
                    probe.invocations += 1
                    return WriteResult.applied
                }
                return nil
            } catch {
                return dispatch.failure(error, invalidatesPriorUndo: false)
            }
        }.value
        #expect(probe.invocations == 1)
        #expect(dispatch.dispatched)
        #expect(outcome == .unconfirmed(.cancelled))
    }
}

extension ReplacementDispatchStateTests {
    @Test func acknowledgedNativeWriteCannotDispatchSecondMutation() throws {
        let dispatch = ReplacementDispatchState()
        var setters = 0
        var pastes = 0
        try dispatch.perform { setters += 1 }
        do {
            try dispatch.perform { pastes += 1 }
            Issue.record("An acknowledged native write must never be followed by paste")
        } catch {
            #expect(error as? ImrseError == .replacementFailed)
        }
        #expect(setters == 1)
        #expect(pastes == 0)
        #expect(dispatch.failure(ImrseError.replacementFailed, invalidatesPriorUndo: true)
            == .unconfirmed(.replacementFailed))
    }

    @Test func qualifiedUpfrontRouteDoesNotDispatchNativeSetter() throws {
        let dispatch = ReplacementDispatchState()
        var setters = 0
        var pastes = 0
        let clipboard = QualifiedClipboardRoute.prefersClipboard(enabled: true,
            applicationID: "ai.capy.desktop", role: "AXTextArea", intent: .replaceSelection,
            verifiedWebArea: true)
        if clipboard { try dispatch.perform { pastes += 1 } }
        else { try dispatch.perform { setters += 1 } }
        #expect(setters == 0)
        #expect(pastes == 1)
    }
}
