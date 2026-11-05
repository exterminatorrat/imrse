import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct SelectionTransactionTests {
    @Test
    func fallbackIsAllowedOnlyWhenMutationIsProvenNotApplied() {
        let applied: SelectionMutationOutcome<String> = .confirmedApplied("receipt")
        let notApplied: SelectionMutationOutcome<String> = .provedNotApplied
        let indeterminate: SelectionMutationOutcome<String> = .indeterminate(.replacementReadbackFailed)

        #expect(!applied.allowsFallback)
        #expect(notApplied.allowsFallback)
        #expect(!indeterminate.allowsFallback)
    }

    @Test
    func confirmedAppliedPreservesItsPayload() {
        let expectedPayload = "applied-receipt"
        let outcome: SelectionMutationOutcome<String> = .confirmedApplied(expectedPayload)

        if case let .confirmedApplied(payload) = outcome {
            #expect(payload == expectedPayload)
        } else {
            Issue.record("Expected the applied payload to be preserved")
        }
    }

    @Test
    func indeterminatePreservesItsFailureReason() {
        let expectedReason = SelectionFailureReason.replacementEvidenceMismatch
        let outcome: SelectionMutationOutcome<String> = .indeterminate(expectedReason)

        if case let .indeterminate(reason) = outcome {
            #expect(reason == expectedReason)
        } else {
            Issue.record("Expected the indeterminate failure reason to be preserved")
        }
    }

    @Test
    func evidenceScenariosRemainConservative() {
        let scenarios: [(name: String, outcome: SelectionMutationOutcome<String>)] = [
            ("confirmed no-op", .provedNotApplied),
            ("readback unknown", .indeterminate(.replacementReadbackFailed)),
            ("rejected write", .indeterminate(.replacementWriteRejected)),
            ("contradictory readback", .indeterminate(.replacementEvidenceMismatch))
        ]

        for scenario in scenarios {
            switch scenario.name {
            case "confirmed no-op":
                guard case .provedNotApplied = scenario.outcome else {
                    Issue.record("A confirmed no-op must be proved not applied")
                    continue
                }
                #expect(scenario.outcome.allowsFallback)
            case "readback unknown":
                guard case let .indeterminate(reason) = scenario.outcome else {
                    Issue.record("Unknown readback must remain indeterminate")
                    continue
                }
                #expect(reason == .replacementReadbackFailed)
                #expect(!scenario.outcome.allowsFallback)
            case "rejected write":
                guard case let .indeterminate(reason) = scenario.outcome else {
                    Issue.record("A rejected write must remain indeterminate")
                    continue
                }
                #expect(reason == .replacementWriteRejected)
                #expect(!scenario.outcome.allowsFallback)
            case "contradictory readback":
                guard case let .indeterminate(reason) = scenario.outcome else {
                    Issue.record("Contradictory readback must remain indeterminate")
                    continue
                }
                #expect(reason == .replacementEvidenceMismatch)
                #expect(!scenario.outcome.allowsFallback)
            default:
                Issue.record("Unexpected scenario: \(scenario.name)")
            }
        }
    }

    @Test
    func capabilityFlagsAdmitOnlyTheirMappedStrategies() {
        for selectedTextSettable in [false, true] {
            for permitsWholeValueWrite in [false, true] {
                for clipboardFallbackEnabled in [false, true] {
                    let capabilities = SelectionWriteCapabilities(
                        selectedTextSettable: selectedTextSettable,
                        permitsWholeValueWrite: permitsWholeValueWrite,
                        clipboardFallbackEnabled: clipboardFallbackEnabled
                    )

                    #expect(capabilities.canConsider(.selectedText) == selectedTextSettable)
                    #expect(capabilities.canConsider(.valueRange) == permitsWholeValueWrite)
                    #expect(capabilities.canConsider(.clipboard) == clipboardFallbackEnabled)
                }
            }
        }

        let allStrategiesAdmissible = SelectionWriteCapabilities(
            selectedTextSettable: true,
            permitsWholeValueWrite: true,
            clipboardFallbackEnabled: true
        )
        let uncertainOutcome: SelectionMutationOutcome<String> = .indeterminate(.replacementReadbackFailed)

        #expect(allStrategiesAdmissible.canConsider(.selectedText))
        #expect(allStrategiesAdmissible.canConsider(.valueRange))
        #expect(allStrategiesAdmissible.canConsider(.clipboard))
        #expect(!uncertainOutcome.allowsFallback)
    }
}
