import XCTest
@testable import ImrseMac
import ImrseCore

final class QualifiedClipboardRouteTests: XCTestCase {
    func testChromeQualificationDoesNotAdmitOtherChromiumBundlesOrNativeChromeFields() {
        for host in ["org.chromium.Chromium", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.example.Chrome"] {
            XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: host,
                role: "AXTextField", intent: .replaceSelection, verifiedWebArea: true))
        }
        XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: "com.google.Chrome",
            role: "AXTextField", intent: .replaceSelection, verifiedWebArea: false))
        XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: "com.google.Chrome",
            role: "AXSecureTextField", intent: .replaceSelection, verifiedWebArea: true))
    }

    func testRequiresEveryQualification() {
        for host in ["com.apple.Safari", "com.vivaldi.Vivaldi", "ai.capy.desktop", "com.google.Chrome"] {
            for role in ["AXTextField", "AXTextArea"] {
                XCTAssertTrue(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: host,
                    role: role, intent: .replaceSelection, verifiedWebArea: true))
                XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: false, applicationID: host,
                    role: role, intent: .replaceSelection, verifiedWebArea: true))
                XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: host,
                    role: role, intent: .replaceSelection, verifiedWebArea: false))
                XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: host,
                    role: role, intent: .insertAtCaret, verifiedWebArea: true))
            }
        }
        XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: "com.apple.TextEdit",
            role: "AXTextArea", intent: .replaceSelection, verifiedWebArea: true))
        XCTAssertFalse(QualifiedClipboardRoute.prefersClipboard(enabled: true, applicationID: "ai.capy.desktop",
            role: "AXSecureTextField", intent: .replaceSelection, verifiedWebArea: true))
    }
}

extension QualifiedClipboardRouteTests {
    func testAncestryRejectsCycleForeignContextAndBudgetExhaustion() {
        func proof(budget: Bool = true, foreign: Bool = false, cycle: Bool = false) -> Bool {
            QualifiedClipboardRoute.verifiesWebArea(root: 0, hasBudget: { budget }, same: ==,
                isSameProcessAndWindow: { _ in !foreign }, isWebArea: { $0 == 2 },
                parent: { cycle ? 0 : $0 + 1 })
        }
        XCTAssertTrue(proof())
        XCTAssertFalse(proof(budget: false))
        XCTAssertFalse(proof(foreign: true))
        XCTAssertFalse(proof(cycle: true))
        XCTAssertFalse(QualifiedClipboardRoute.verifiesWebArea(root: 0,
            hasBudget: { true }, same: ==, isSameProcessAndWindow: { _ in true },
            isWebArea: { $0 == 33 }, parent: { $0 + 1 }))
    }
}
