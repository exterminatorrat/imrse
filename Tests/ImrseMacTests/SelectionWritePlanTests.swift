import XCTest
import ImrseCore
@testable import ImrseMac

final class SelectionWritePlanTests: XCTestCase {
    private enum ProbeError: Error { case unexpectedProbe }

    func testQualifiedClipboardBypassesNativeCapabilityProbes() throws {
        let plan = try SelectionWritePlan.choose(prefersQualifiedClipboard: true, clipboardEnabled: true,
            selectedTextSettable: { throw ProbeError.unexpectedProbe }, wholeValueAvailable: true,
            valueSettable: { throw ProbeError.unexpectedProbe })
        XCTAssertEqual(plan, .clipboard)
    }

    func testDisabledClipboardRetainsNativePriorityEvenIfPreferenceIsSet() throws {
        let plan = try SelectionWritePlan.choose(prefersQualifiedClipboard: true, clipboardEnabled: false,
            selectedTextSettable: { true }, wholeValueAvailable: true,
            valueSettable: { throw ProbeError.unexpectedProbe })
        XCTAssertEqual(plan, .selectedText)
    }

    func testWholeValueOnlyAfterSelectedTextUnavailableAndBaselineAvailable() throws {
        var probes: [String] = []
        let plan = try SelectionWritePlan.choose(prefersQualifiedClipboard: false, clipboardEnabled: true,
            selectedTextSettable: { probes.append("selectedText"); return false }, wholeValueAvailable: true,
            valueSettable: { probes.append("value"); return true })
        XCTAssertEqual(plan, .valueRange)
        XCTAssertEqual(probes, ["selectedText", "value"])
    }

    func testNoBaselineNeverProbesWholeValueWrite() throws {
        for enabled in [false, true] {
            let plan = try SelectionWritePlan.choose(prefersQualifiedClipboard: false, clipboardEnabled: enabled,
                selectedTextSettable: { false }, wholeValueAvailable: false,
                valueSettable: { throw ProbeError.unexpectedProbe })
            XCTAssertEqual(plan, enabled ? .clipboard : nil)
        }
    }

    func testCapabilityErrorRefusesRatherThanChoosingAnotherMutationRoute() {
        XCTAssertThrowsError(try SelectionWritePlan.choose(prefersQualifiedClipboard: false, clipboardEnabled: true,
            selectedTextSettable: { throw ProbeError.unexpectedProbe }, wholeValueAvailable: true,
            valueSettable: { true }))
    }
}
