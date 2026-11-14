import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@MainActor
struct NativeRefusalClassificationTests {
    @Test(arguments: [
        NativeRefusalDiagnostic.UndoStage.preflight,
        .pasteEntry,
        .stage,
        .verify
    ])
    func noRouteOutsideUndoClassifiesNothing(stage: NativeRefusalDiagnostic.UndoStage) {
        #expect(NativeRefusalClassification.undo(route: nil, stage: stage) == nil)
        #expect(NativeRefusalClassification.undo(route: nil, stage: stage, style: .styleMismatch) == nil)
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.UndoRoute.generic,
        .uniform,
        .structured
    ], [
        NativeRefusalDiagnostic.UndoStage.preflight,
        .pasteEntry,
        .stage,
        .verify
    ])
    func everyRouteAndStageIsIdentifiable(
        route: NativeRefusalDiagnostic.UndoRoute,
        stage: NativeRefusalDiagnostic.UndoStage
    ) throws {
        let diagnostic = try #require(NativeRefusalClassification.undo(route: route, stage: stage))
        #expect(diagnostic.undo?.route == route)
        #expect(diagnostic.undo?.stage == stage)
        #expect(diagnostic.undo?.style == nil)
        #expect(diagnostic.focus == nil)
    }

    @Test func undoClassificationKeepsRoutesDistinctWhenTheBroadReasonIsIdentical() throws {
        let genericPreflight = try #require(NativeRefusalClassification.undo(route: .generic, stage: .preflight))
        let uniformStage = try #require(NativeRefusalClassification.undo(route: .uniform, stage: .stage))
        let structuredVerify = try #require(NativeRefusalClassification.undo(
            route: .structured,
            stage: .verify,
            style: .projectionMismatch
        ))

        #expect(genericPreflight != uniformStage)
        #expect(uniformStage != structuredVerify)
        #expect(Set([genericPreflight, uniformStage, structuredVerify].compactMap { $0.undo?.route.rawValue })
            == Set(["generic", "uniform", "structured"]))
        #expect(genericPreflight.undo?.stage == .preflight)
        #expect(uniformStage.undo?.stage == .stage)
        #expect(structuredVerify.undo?.style == .projectionMismatch)
    }

    @Test(arguments: [
        ContenteditableStyleState.rootIneligible,
        .attributedUnavailable,
        .structuredUnavailable,
        .projectionMismatch,
        .styleMismatch
    ])
    func failingStyleStatesAreReportedWithTheirOwnName(state: ContenteditableStyleState) throws {
        let diagnostic = try #require(NativeRefusalClassification.undo(route: .uniform, stage: .stage, style: state))
        #expect(diagnostic.undo?.style?.rawValue == String(describing: state))
    }

    @Test func satisfiedStyleStateCarriesNoStyleDetail() {
        #expect(ContenteditableStyleState.satisfied.reported == nil)
        #expect(NativeRefusalClassification.undo(
            route: .structured,
            stage: .verify,
            style: .satisfied
        )?.undo?.style == nil)
    }

    @Test func focusOutcomeSeparatesMissingReadAndMismatch() {
        #expect(ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: { nil },
            sameElement: { $0 == $1 }
        ) == .missingFocusedElement)

        #expect(ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: { throw FocusReadFailure.unavailable },
            sameElement: { $0 == $1 }
        ) == .readFailed)

        #expect(ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: { 8 },
            sameElement: { $0 == $1 }
        ) == .differentAnchor)

        #expect(ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: { 7 },
            sameElement: { $0 == $1 }
        ) == nil)
    }

    @Test func focusOutcomeReadsTheFocusedElementOnce() {
        var reads = 0
        let outcome = ObservedFocusValidation.outcome(
            capturedElement: 7,
            readFocusedElement: {
                reads += 1
                return 7
            },
            sameElement: { $0 == $1 }
        )

        #expect(outcome == nil)
        #expect(reads == 1)
    }

    @Test func preservedCaptureStillMatchesTheClassification() {
        let targetID = UUID()

        #expect(ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { 7 },
            sameElement: { $0 == $1 }
        ))
        #expect(!ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { nil },
            sameElement: { $0 == $1 }
        ))
        #expect(!ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { throw FocusReadFailure.unavailable },
            sameElement: { $0 == $1 }
        ))
        #expect(!ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: targetID,
            capturedElement: 7,
            readFocusedElement: { 8 },
            sameElement: { $0 == $1 }
        ))
        #expect(!ObservedFocusValidation.preservesCapture(
            observedTargetID: targetID,
            currentTargetID: UUID(),
            capturedElement: 7,
            readFocusedElement: { 7 },
            sameElement: { $0 == $1 }
        ))
    }
}

private enum FocusReadFailure: Error {
    case unavailable
}
