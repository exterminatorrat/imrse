#if os(macOS)
import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct CaptureSelectionFallbackTests {
    @Test
    func capturesDirectlyWithoutResolvingAHost() {
        #expect(CaptureSelectionFallback.route(range: .present, text: .present) == .captured)
    }

    @Test
    func resolvesAHostOnlyForMissingSelectionEvidence() {
        #expect(CaptureSelectionFallback.route(range: .present, text: .absent) == .resolveHost)
        #expect(CaptureSelectionFallback.route(range: .absent, text: .present) == .resolveHost)
        #expect(CaptureSelectionFallback.route(range: .absent, text: .absent) == .resolveHost)
    }

    @Test
    func refusesMalformedEvidenceInsteadOfResolvingAHost() {
        #expect(CaptureSelectionFallback.route(range: .malformed, text: .present) == .refuse)
        #expect(CaptureSelectionFallback.route(range: .present, text: .malformed) == .refuse)
        #expect(CaptureSelectionFallback.route(range: .malformed, text: .malformed) == .refuse)
        #expect(CaptureSelectionFallback.route(range: .malformed, text: .absent) == .refuse)
        #expect(CaptureSelectionFallback.route(range: .absent, text: .malformed) == .refuse)
    }

    @Test
    func refusesAnExplicitEmptyReplacementSelectionBeforeRouting() {
        let empty = ImrseCore.TextRange(location: 0, length: 0)

        #expect(SelectionReadValidation.rangeFailure(empty, allowingEmpty: false) == .emptySelection)
        #expect(CaptureSelectionFallback.route(range: .present, text: .present) == .captured)
    }

    @Test
    func agreesWhenTheAnchorAdvertisesNothingOrMatchesTheHost() {
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .absent,
            anchorRangeMatchesHost: false,
            anchorText: .absent,
            anchorTextMatchesHost: false
        ) == .agrees)
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .present,
            anchorRangeMatchesHost: true,
            anchorText: .absent,
            anchorTextMatchesHost: false
        ) == .agrees)
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .present,
            anchorRangeMatchesHost: true,
            anchorText: .present,
            anchorTextMatchesHost: true
        ) == .agrees)
    }

    @Test
    func refusesContradictedAnchorEvidence() {
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .present,
            anchorRangeMatchesHost: false,
            anchorText: .present,
            anchorTextMatchesHost: true
        ) == .rangeMismatch)
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .present,
            anchorRangeMatchesHost: true,
            anchorText: .present,
            anchorTextMatchesHost: false
        ) == .textMismatch)
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .absent,
            anchorRangeMatchesHost: false,
            anchorText: .present,
            anchorTextMatchesHost: false
        ) == .textMismatch)
    }

    @Test
    func refusesUnreadableAnchorEvidence() {
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .malformed,
            anchorRangeMatchesHost: true,
            anchorText: .present,
            anchorTextMatchesHost: true
        ) == .malformed)
        #expect(CaptureSelectionFallback.anchorAgreement(
            anchorRange: .present,
            anchorRangeMatchesHost: true,
            anchorText: .malformed,
            anchorTextMatchesHost: true
        ) == .malformed)
    }
}
#endif
