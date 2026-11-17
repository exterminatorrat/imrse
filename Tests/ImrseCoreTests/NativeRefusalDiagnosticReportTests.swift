import Foundation
import Testing
@testable import ImrseCore

struct NativeRefusalDiagnosticReportTests {
    @Test(arguments: [NativeRefusalDiagnostic.FocusSite.observer, .targetAnchor, .editableHost])
    func focusOwnershipContainsOnlyClosedSiteAndBooleans(_ site: NativeRefusalDiagnostic.FocusSite) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focusSite: site,
            panelOwnership: .init(isKey: true, ownAppActive: false, activationRequested: true),
            focus: .differentAnchor, focusRead: .resolved)
        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(Set(refusal.keys) == Set(["focusSite", "panelOwnership", "focus", "focusRead"]))
        #expect(refusal["focusSite"] as? String == site.rawValue)
        let ownership = try #require(refusal["panelOwnership"] as? [String: Bool])
        #expect(ownership == ["isKey": true, "ownAppActive": false, "activationRequested": true])
    }

    @Test func unavailableHostDoesNotClaimDifferentIdentity() throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focusSite: .editableHost)
        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(Set(refusal.keys) == Set(["focusSite"]))
        #expect(refusal["focusSite"] as? String == "editableHost")
        #expect(refusal["focus"] == nil)
    }

    @Test(arguments: [NativeRefusalDiagnostic.FocusSite.targetAnchor, .editableHost, .observer])
    func actualAttachmentPreservesCurrentOwnershipEvidence(_ site: NativeRefusalDiagnostic.FocusSite) throws {
        var metadata = DiagnosticMetadata()
        metadata.error = site == .observer ? .targetLost : .staleSelection
        metadata.selectionFailureReason = site == .observer ? .captureObservedFocusChange : .focusedElementChanged
        let ownership = NativeRefusalDiagnostic.PanelOwnership(isKey: true, ownAppActive: false, activationRequested: true)
        metadata.attachNativeRefusal(.init(focusSite: site, panelOwnership: ownership,
            focus: site == .editableHost ? nil : .differentAnchor, focusRead: .resolved))
        #expect(metadata.nativeRefusalDiagnostic?.focusSite == site)
        #expect(metadata.nativeRefusalDiagnostic?.panelOwnership == ownership)
        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["focusSite"] as? String == site.rawValue)
        #expect(refusal["panelOwnership"] != nil)
        metadata.error = .cancelled
        metadata.attachNativeRefusal(metadata.nativeRefusalDiagnostic)
        #expect(metadata.nativeRefusalDiagnostic == nil)
    }

    @Test func observationIsHistoricalAndDoesNotInventAnOperationFailure() throws {
        let event = NativeRefusalDiagnostic(focusSite: .observer,
            panelOwnership: .init(isKey: true, ownAppActive: false, activationRequested: true),
            undo: .init(route: .generic, stage: .preflight), focus: .missingFocusedElement,
            focusRead: .noValue, foreground: .target, panelPhase: .presentationReturned,
            presentationStage: .input)
        let observation = try #require(CaptureFocusObservation(event))
        #expect(observation.evidence.undo == nil)
        var metadata = DiagnosticMetadata()
        for error: ImrseError? in [nil, .cancelled, .network] {
            metadata.error = error
            metadata.attachNativeRefusal(observation.evidence)
            let json = DiagnosticReport.render(metadata, lastCaptureFocusObservation: observation)
            let report = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let eventFields = try #require(report["lastCaptureFocusObservation"] as? [String: Any])
            #expect(eventFields["event"] as? String == "captureInvalidatedByFocusObservation")
            #expect(eventFields["undo"] == nil)
            #expect(eventFields["captureFocus"] == nil)
            #expect(report["nativeRefusal"] == nil)
            #expect(report["generation"] as? String == "idle")
            #expect(report["replacement"] as? String == "idle")
            #expect(report["targetValid"] == nil)
        }
        let reset = DiagnosticReport.render(metadata, lastCaptureFocusObservation: nil)
        #expect(!reset.contains("lastCaptureFocusObservation"))
        #expect(CaptureFocusObservation(.init(focusSite: .targetAnchor, focus: .differentAnchor)) == nil)
        #expect(CaptureFocusObservation(.init(focusSite: .observer)) == nil)
    }

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

    @Test func focusEvidenceRendersBesideTheBroadOutcome() throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(
            focus: .differentAnchor,
            focusRead: .resolved,
            foreground: .own,
            panelPhase: .handoffHideReturned
        )

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(Set(refusal.keys) == Set(["focus", "focusRead", "foreground", "panelPhase"]))
        #expect(refusal["focus"] as? String == "differentAnchor")
        #expect(refusal["focusRead"] as? String == "resolved")
        #expect(refusal["foreground"] as? String == "own")
        #expect(refusal["panelPhase"] as? String == "handoffHideReturned")
    }

    @Test func attachedFocusEvidenceSurvivesOnlyItsCurrentFailure() throws {
        let diagnostic = NativeRefusalDiagnostic(
            undo: .init(route: .generic, stage: .preflight),
            focus: .missingFocusedElement,
            focusRead: .noValue,
            foreground: .target,
            panelPhase: .presentationReturned
        )
        var metadata = DiagnosticMetadata()
        metadata.error = .targetLost
        metadata.selectionFailureReason = .captureObservedFocusChange
        metadata.attachNativeRefusal(diagnostic)
        #expect(metadata.nativeRefusalDiagnostic == diagnostic)
        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["focusRead"] as? String == "noValue")
        #expect(refusal["foreground"] as? String == "target")
        #expect(refusal["panelPhase"] as? String == "presentationReturned")

        metadata.error = .network
        metadata.attachNativeRefusal(diagnostic)
        #expect(metadata.nativeRefusalDiagnostic == .init(undo: diagnostic.undo))
        let unrelated = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(Set(unrelated.keys) == Set(["undo"]))

        metadata.error = nil
        metadata.attachNativeRefusal(diagnostic)
        #expect(metadata.nativeRefusalDiagnostic == nil)
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.FocusRead.resolved,
        .noValue,
        .attributeUnsupported,
        .successWithoutElement,
        .unexpectedValueType,
        .readFailed
    ])
    func everyFocusReadRendersItsOwnName(_ read: NativeRefusalDiagnostic.FocusRead) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focus: .missingFocusedElement, focusRead: read)

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["focusRead"] as? String == read.rawValue)
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.ForegroundRelation.target,
        .own,
        .other,
        .unavailable
    ])
    func everyForegroundRelationRendersItsOwnName(
        _ relation: NativeRefusalDiagnostic.ForegroundRelation
    ) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focus: .readFailed, foreground: relation)

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["foreground"] as? String == relation.rawValue)
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.PanelPhase.unavailable,
        .presentationRequested,
        .presentationReturned,
        .hideRequested,
        .hideReturned,
        .handoffHideRequested,
        .handoffHideReturned
    ])
    func everyPanelPhaseRendersItsOwnName(_ phase: NativeRefusalDiagnostic.PanelPhase) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focus: .readFailed, panelPhase: phase)

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["panelPhase"] as? String == phase.rawValue)
    }

    @Test(arguments: [
        NativeRefusalDiagnostic.PresentationStage.unavailable,
        .hidden,
        .input,
        .processing,
        .applying,
        .success,
        .failure
    ])
    func everyPresentationStageRendersItsOwnName(_ stage: NativeRefusalDiagnostic.PresentationStage) throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(focus: .missingFocusedElement, presentationStage: stage)

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["presentationStage"] as? String == stage.rawValue)
    }

    @Test func presentationStageFollowsItsFocusEvidenceThroughAttachment() throws {
        let diagnostic = NativeRefusalDiagnostic(
            undo: .init(route: .generic, stage: .preflight),
            focus: .missingFocusedElement,
            focusRead: .noValue,
            foreground: .target,
            panelPhase: .presentationReturned,
            presentationStage: .input
        )
        var metadata = DiagnosticMetadata()
        metadata.error = .targetLost
        metadata.selectionFailureReason = .captureObservedFocusChange
        metadata.attachNativeRefusal(diagnostic)

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["presentationStage"] as? String == "input")

        metadata.selectionFailureReason = .captureObservedSelectionChange
        metadata.attachNativeRefusal(diagnostic)
        let unrelated = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(Set(unrelated.keys) == Set(["undo"]))
    }

    @Test func focusEvidenceValuesStayInsideTheirClosedSets() throws {
        var metadata = DiagnosticMetadata()
        metadata.nativeRefusalDiagnostic = .init(
            focus: .missingFocusedElement,
            focusRead: .successWithoutElement,
            foreground: .other,
            panelPhase: .hideRequested
        )

        let refusal = try #require(try fields(metadata)["nativeRefusal"] as? [String: Any])
        #expect(refusal["presentationStage"] == nil)
        #expect(Set(["resolved", "noValue", "attributeUnsupported", "successWithoutElement",
                     "unexpectedValueType", "readFailed"]).contains(refusal["focusRead"] as? String ?? ""))
        #expect(Set(["target", "own", "other", "unavailable"]).contains(refusal["foreground"] as? String ?? ""))
        #expect(Set(["unavailable", "presentationRequested", "presentationReturned", "hideRequested",
                     "hideReturned", "handoffHideRequested", "handoffHideReturned"])
            .contains(refusal["panelPhase"] as? String ?? ""))
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
