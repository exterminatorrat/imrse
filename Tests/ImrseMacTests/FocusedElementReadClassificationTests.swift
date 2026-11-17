import ApplicationServices
import ImrseCore
import Testing
@testable import ImrseMac

@MainActor
struct FocusedElementReadClassificationTests {
    @Test func aResolvedElementIsTheOnlySuccessfulElementRead() {
        let read = NativeRefusalClassification.focusRead(status: .success, hasValue: true, isElement: true)
        #expect(read == .resolved)
        #expect(!read.isReadFailure)
    }

    @Test func absentAttributesStayMissingRatherThanFailingTheRead() {
        let noValue = NativeRefusalClassification.focusRead(status: .noValue, hasValue: false, isElement: false)
        #expect(noValue == .noValue)
        #expect(!noValue.isReadFailure)

        let unsupported = NativeRefusalClassification.focusRead(
            status: .attributeUnsupported,
            hasValue: false,
            isElement: false
        )
        #expect(unsupported == .attributeUnsupported)
        #expect(!unsupported.isReadFailure)
    }

    @Test func successfulStatusStillSeparatesAbsentAndWrongTypeValues() {
        let absent = NativeRefusalClassification.focusRead(status: .success, hasValue: false, isElement: false)
        #expect(absent == .successWithoutElement)
        #expect(absent.isReadFailure)

        let wrongType = NativeRefusalClassification.focusRead(status: .success, hasValue: true, isElement: false)
        #expect(wrongType == .unexpectedValueType)
        #expect(wrongType.isReadFailure)
    }

    @Test func otherStatusesStayOneClosedFailure() {
        for status in [
            AXError.failure,
            .cannotComplete,
            .apiDisabled,
            .invalidUIElement,
            .notImplemented
        ] {
            let read = NativeRefusalClassification.focusRead(status: status, hasValue: true, isElement: true)
            #expect(read == .readFailed)
            #expect(read.isReadFailure)
        }
    }

    @Test func readFailuresStayLimitedToTheThreeFailingShapes() {
        let failing: [NativeRefusalDiagnostic.FocusRead] = [
            .successWithoutElement,
            .unexpectedValueType,
            .readFailed
        ]
        let everyCase: [NativeRefusalDiagnostic.FocusRead] = [
            .resolved,
            .noValue,
            .attributeUnsupported,
            .successWithoutElement,
            .unexpectedValueType,
            .readFailed
        ]
        for read in everyCase {
            #expect(read.isReadFailure == failing.contains(read))
        }
    }

    @Test func classificationAgreesWithTheBroadFocusOutcome() {
        let missing = NativeRefusalClassification.focusRead(status: .noValue, hasValue: false, isElement: false)
        #expect(!missing.isReadFailure)
        #expect(ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: { nil },
            sameElement: { $0 == $1 }
        ) == .missingFocusedElement)

        let failed = NativeRefusalClassification.focusRead(
            status: .cannotComplete,
            hasValue: false,
            isElement: false
        )
        #expect(failed.isReadFailure)
        #expect(ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: { throw FocusObservationReadFailure.unavailable },
            sameElement: { $0 == $1 }
        ) == .readFailed)
    }

    @Test func theOutcomeIsStillDecidedByOneRead() {
        var missingReads = 0
        _ = ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: {
                missingReads += 1
                return nil
            },
            sameElement: { $0 == $1 }
        )
        #expect(missingReads == 1)

        var failedReads = 0
        _ = ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: {
                failedReads += 1
                throw FocusObservationReadFailure.unavailable
            },
            sameElement: { $0 == $1 }
        )
        #expect(failedReads == 1)
    }

    @Test func panelPhaseDefaultsToUnavailable() {
        #expect(MacSelectionAccess().focusObservationPanelPhase == .unavailable)
        #expect(MacSelectionAccess().focusObservationPresentationStage == .unavailable)
    }

    @Test func thePanelPhaseContractKeepsItsFrozenNames() {
        #expect(NativeRefusalDiagnostic.PanelPhase.unavailable.rawValue == "unavailable")
        #expect(NativeRefusalDiagnostic.PanelPhase.presentationRequested.rawValue == "presentationRequested")
        #expect(NativeRefusalDiagnostic.PanelPhase.presentationReturned.rawValue == "presentationReturned")
        #expect(NativeRefusalDiagnostic.PanelPhase.hideRequested.rawValue == "hideRequested")
        #expect(NativeRefusalDiagnostic.PanelPhase.hideReturned.rawValue == "hideReturned")
        #expect(NativeRefusalDiagnostic.PanelPhase.handoffHideRequested.rawValue == "handoffHideRequested")
        #expect(NativeRefusalDiagnostic.PanelPhase.handoffHideReturned.rawValue == "handoffHideReturned")
    }

    @Test func thePresentationStageContractKeepsItsFrozenNames() {
        #expect(NativeRefusalDiagnostic.PresentationStage.unavailable.rawValue == "unavailable")
        #expect(NativeRefusalDiagnostic.PresentationStage.hidden.rawValue == "hidden")
        #expect(NativeRefusalDiagnostic.PresentationStage.input.rawValue == "input")
        #expect(NativeRefusalDiagnostic.PresentationStage.processing.rawValue == "processing")
        #expect(NativeRefusalDiagnostic.PresentationStage.applying.rawValue == "applying")
        #expect(NativeRefusalDiagnostic.PresentationStage.success.rawValue == "success")
        #expect(NativeRefusalDiagnostic.PresentationStage.failure.rawValue == "failure")
    }
}

private enum FocusObservationReadFailure: Error {
    case unavailable
}
