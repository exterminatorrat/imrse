#if os(macOS)
import AppKit
import ImrsePillCore
import Testing
@testable import ImrseApp
@testable import ImrseMac

@MainActor
struct PillPanelFocusPolicyTests {
    @Test(arguments: [
        PillPhase.hidden, .success(UUID()), .failure(UUID(), "Provider failure")
    ])
    func terminalLifecycleConsumesThePresentationReturnOnce(_ phase: PillPhase) {
        let counter = FocusReturnCounter()
        let session = PillPresentationFocusSession()
        session.begin(makeToken(counter))
        session.didChange(to: phase)
        session.didChange(to: .hidden)
        #expect(counter.count == 1)
    }

    @Test func inputAndProcessingKeepOwnershipUntilCancellationOrDismissal() {
        let counter = FocusReturnCounter()
        let session = PillPresentationFocusSession()
        session.begin(makeToken(counter))
        let id = UUID()
        for phase in [PillPhase.input, .processing(id), .applying(id)] {
            session.didChange(to: phase)
        }
        #expect(counter.count == 0)
        session.didChange(to: .hidden)
        #expect(counter.count == 1)
    }

    @Test func settingsInvalidationBeforeDismissalDoesNotReturnToTheOldApp() {
        let counter = FocusReturnCounter()
        let session = PillPresentationFocusSession()
        session.begin(makeToken(counter))
        session.invalidate()
        session.didChange(to: .hidden)
        #expect(counter.count == 0)
    }

    @Test func newerPresentationRevokesThePreviousReturnToken() {
        let oldCounter = FocusReturnCounter()
        let newCounter = FocusReturnCounter()
        let session = PillPresentationFocusSession()
        let oldToken = makeToken(oldCounter)
        session.begin(oldToken)
        session.begin(makeToken(newCounter))
        oldToken.finishPresentation()
        #expect(oldCounter.count == 0)
        session.didChange(to: .hidden)
        #expect(newCounter.count == 1)
    }

    @Test func feedbackAndUndoPanelRetainsNonactivatingInteractionStyle() {
        #expect(PillPanelController.panelStyleMask.contains(.nonactivatingPanel))
        #expect(PillPanelController.panelStyleMask.contains(.borderless))
    }

    @Test func onlyInputPresentationRequestsKeyFocusAndExplicitActivation() {
        let id = UUID()
        #expect(PillPanelController.acceptsInputFocus(for: .input))
        for phase in [
            PillPhase.hidden, .processing(id), .applying(id), .success(id), .failure(id, "Failure")
        ] {
            #expect(!PillPanelController.acceptsInputFocus(for: phase))
        }
    }

    @Test func foregroundEscapeDismissesTheNonKeyTerminalFeedback() {
        let id = UUID()
        for phase in [PillPhase.success(id), .failure(id, "Provider failure")] {
            #expect(!PillPanelController.acceptsInputFocus(for: phase))
            #expect(PillPanelController.dismissesOnForegroundEscape(for: phase))
        }
    }

    @Test func foregroundEscapeLeavesInputAndInFlightPresentationsAlone() {
        let id = UUID()
        for phase in [PillPhase.hidden, .input, .processing(id), .applying(id)] {
            #expect(!PillPanelController.dismissesOnForegroundEscape(for: phase))
        }
    }

    @Test func foregroundEscapeRequiresAPlainUnmodifiedPress() {
        #expect(PillPanelController.isPlainEscape(keyCode: 53, isRepeat: false, modifiers: []))
        #expect(PillPanelController.isPlainEscape(keyCode: 53, isRepeat: false, modifiers: .function))
        #expect(PillPanelController.isPlainEscape(keyCode: 53, isRepeat: false, modifiers: .capsLock))
        #expect(!PillPanelController.isPlainEscape(keyCode: 53, isRepeat: true, modifiers: []))
        for modifier in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            #expect(!PillPanelController.isPlainEscape(keyCode: 53, isRepeat: false, modifiers: modifier))
        }
        #expect(!PillPanelController.isPlainEscape(keyCode: 36, isRepeat: false, modifiers: []))
    }

    private func makeToken(_ counter: FocusReturnCounter) -> ApplicationFocusReturn {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return ApplicationFocusReturn(
            original: .init(processID: 101, launchDate: date),
            ownProcessID: 202,
            originalIsAlive: { true },
            foreground: { .init(processID: 202, launchDate: date) },
            activateOriginal: {
                counter.count += 1
                return true
            }
        )
    }
}

@MainActor
private final class FocusReturnCounter {
    var count = 0
}
#endif
