import Foundation
import Testing
@testable import ImrseCore

struct NativeRefusalDiagnosticReportTests {
    @Test func refusalIsAbsentByDefault() throws {
        let metadata = DiagnosticMetadata()
        #expect(metadata.nativeRefusalDiagnostic == nil)
        #expect(try fields(metadata)["nativeRefusal"] == nil)
    }

    @Test func undoRefusalRendersOnlyClosedValues() throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(undo: .init(
            route: .uniform,
            stage: .stage,
            style: .attributedUnavailable
        ))

        let report = try fields(metadata)
        let refusal = try #require(report["nativeRefusal"] as? [String: Any])
        #expect(Set(refusal.keys) == Set(["undo"]))
        let undo = try #require(refusal["undo"] as? [String: Any])
        #expect(Set(undo.keys) == Set(["route", "stage", "style"]))
        #expect(undo["route"] as? String == "uniform")
        #expect(undo["stage"] as? String == "stage")
        #expect(undo["style"] as? String == "attributedUnavailable")
        #expect(Set(report.keys) == Set([
            "accessibilityGranted", "eventMonitoringActive", "generation", "replacement", "nativeRefusal"
        ]))
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.UndoRoute.generic,
        .uniform,
        .structured
    ])
    func everyRouteRendersItsOwnName(_ route: NativeRefusalDiagnostic.UndoRoute) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(undo: .init(route: route, stage: .preflight))

        let undo = try undoFields(metadata)
        #expect(undo["route"] as? String == route.rawValue)
        #expect(Set(undo.keys) == Set(["route", "stage"]))
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.UndoStage.preflight,
        .pasteEntry,
        .stage,
        .verify
    ])
    func everyStageRendersItsOwnName(_ stage: NativeRefusalDiagnostic.UndoStage) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(undo: .init(route: .structured, stage: stage))

        let undo = try undoFields(metadata)
        #expect(undo["stage"] as? String == stage.rawValue)
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.StyleState.rootIneligible,
        .attributedUnavailable,
        .structuredUnavailable,
        .projectionMismatch,
        .styleMismatch
    ])
    func everyStyleStateRendersItsOwnName(_ style: NativeRefusalDiagnostic.StyleState) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(undo: .init(route: .uniform, stage: .verify, style: style))

        let undo = try undoFields(metadata)
        #expect(undo["style"] as? String == style.rawValue)
    }

    @Test func focusOutcomeRendersWithoutAnUndoRoute() throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focus: .differentAnchor)

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(Set(refusal.keys) == Set(["focus"]))
        #expect(refusal["focus"] as? String == "differentAnchor")
        #expect(refusal["undo"] == nil)
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.FocusOutcome.missingFocusedElement,
        .readFailed,
        .differentAnchor
    ])
    func everyFocusOutcomeRendersItsOwnName(_ outcome: NativeRefusalDiagnostic.FocusOutcome) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focus: outcome)

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["focus"] as? String == outcome.rawValue)
    }

    @Test func refusalCoexistsWithTheBroadFailureReasonWithoutReplacingIt() throws {
        var metadata = DiagnosticMetadata()
        metadata.selectionFailureReason = .clipboardTargetIneligible
        metadata.targetValid = false
        metadata.strategy = .clipboard
        metadata.nativeRefusalDiagnostic = .init(undo: .init(route: .generic, stage: .preflight))

        let report = try fields(metadata)
        #expect(report["selectionFailureReason"] as? String == "clipboardTargetIneligible")
        #expect(report["targetValid"] as? Bool == false)
        #expect(report["strategy"] as? String == "clipboard")
        let refusal = try #require(report["nativeRefusal"] as? [String: Any])
        let undo = try #require(refusal["undo"] as? [String: Any])
        #expect(undo["route"] as? String == "generic")
        #expect(undo["stage"] as? String == "preflight")
    }

    @Test func refusalIsAttachedOnlyWhileAFailureIsReported() throws {
        let refusal = NativeRefusalDiagnostic(undo: .init(
            route: .uniform,
            stage: .stage,
            style: .styleMismatch
        ))

        var failure = DiagnosticMetadata()
        failure.error = .undoUnavailable
        failure.attachNativeRefusal(refusal)
        #expect(failure.nativeRefusalDiagnostic == refusal)

        var succeeded = DiagnosticMetadata()
        succeeded.attachNativeRefusal(refusal)
        #expect(succeeded.nativeRefusalDiagnostic == nil)
        #expect(try fields(succeeded)["nativeRefusal"] == nil)

        var cleared = DiagnosticMetadata()
        cleared.error = .undoUnavailable
        cleared.attachNativeRefusal(nil)
        #expect(try fields(cleared)["nativeRefusal"] == nil)
    }

    @Test(arguments: [ImrseError.network, .cancelled, .server, .targetLost])
    func unrelatedFailuresDoNotInheritAnObservedFocusRefusal(_ error: ImrseError) throws {
        var metadata = DiagnosticMetadata()
        metadata.error = error
        metadata.attachNativeRefusal(.init(focus: .differentAnchor))

        #expect(metadata.nativeRefusalDiagnostic == nil)
        #expect(try fields(metadata)["nativeRefusal"] == nil)
    }

    @Test func focusRefusalRequiresTheCurrentFocusValidationFailure() throws {
        var metadata = DiagnosticMetadata()
        metadata.error = .targetLost
        metadata.selectionFailureReason = .captureObservedFocusChange
        metadata.attachNativeRefusal(.init(focus: .readFailed))

        #expect(metadata.nativeRefusalDiagnostic?.focus == .readFailed)
        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["focus"] as? String == "readFailed")

        metadata.error = .network
        metadata.attachNativeRefusal(.init(focus: .readFailed))
        #expect(metadata.nativeRefusalDiagnostic == nil)
    }

    @Test func droppingUnrelatedFocusDoesNotDropUndoClassification() {
        let undo = NativeRefusalDiagnostic.Undo(route: .generic, stage: .preflight)
        var metadata = DiagnosticMetadata()
        metadata.error = .undoUnavailable
        metadata.attachNativeRefusal(.init(undo: undo, focus: .differentAnchor))

        #expect(metadata.nativeRefusalDiagnostic?.undo == undo)
        #expect(metadata.nativeRefusalDiagnostic?.focus == nil)
    }

    private func undoFields(_ metadata: DiagnosticMetadata) throws -> [String: Any] {
        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        return try #require(refusal["undo"] as? [String: Any])
    }

    private func fields(_ metadata: DiagnosticMetadata) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(
            with: Data(DiagnosticReport.render(metadata).utf8)
        ) as? [String: Any])
    }
}
