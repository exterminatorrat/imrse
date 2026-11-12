import Foundation
import ImrseCore
import Testing
@testable import ImrseMac

@Suite
struct ContenteditableClipboardRecoveryTests {
    private struct ClipboardState {
        var text: String
        var owner: UUID?
    }

    private struct Transaction {
        let originalText: String
        let owner: UUID
        var mutated = false
    }

    @Test
    @MainActor
    func textConfirmationRestoresClipboardButStyleProofRefusesAcceptance() async throws {
        let original = styled("before target after", foreground: "original foreground")
        let proof = try #require(ContenteditableTextStyleProof(
            originalValue: original,
            selectionRange: TextRange(location: 7, length: 6),
            selectedText: "target",
            replacement: "replacement"
        ))
        let confirmedValue = styled("before replacement after", foreground: "different foreground")
        var clipboard = ClipboardState(text: "prior clipboard", owner: nil)
        var restoreCount = 0
        let recovery = ClipboardPasteRecovery<Transaction, UUID>()
        let recoveredValue = try await recovery.perform(
            destination: UUID(),
            capture: {
                Transaction(originalText: clipboard.text, owner: UUID())
            },
            stage: { transaction in
                clipboard.text = proof.expectedValue.string
                clipboard.owner = transaction.owner
                transaction.mutated = true
            },
            verify: { transaction in
                #expect(transaction.mutated)
                #expect(clipboard.owner == transaction.owner)
                #expect(clipboard.text.utf16.elementsEqual(proof.expectedValue.string.utf16))
            },
            post: {},
            confirm: {
                #expect(clipboard.owner != nil)
                #expect(clipboard.text.utf16.elementsEqual(confirmedValue.string.utf16))
                return confirmedValue
            },
            hasMutated: { $0.mutated },
            restore: { transaction in
                guard transaction.mutated, clipboard.owner == transaction.owner else { return false }
                clipboard.text = transaction.originalText
                clipboard.owner = nil
                transaction.mutated = false
                restoreCount += 1
                return true
            }
        )

        #expect(recoveredValue.string.utf16.elementsEqual(proof.expectedValue.string.utf16))
        let editAccepted = proof.confirmsApplied(recoveredValue)
        #expect(!editAccepted)
        #expect(restoreCount == 1)
        #expect(clipboard.text == "prior clipboard")
        #expect(clipboard.owner == nil)
        #expect(!recovery.isBlocked)
    }

    private var fontAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXFont")
    }

    private var foregroundAttribute: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "AXForegroundColor")
    }

    private func styled(_ string: String, foreground: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            fontAttribute: "synthetic font",
            foregroundAttribute: foreground
        ])
    }
}
