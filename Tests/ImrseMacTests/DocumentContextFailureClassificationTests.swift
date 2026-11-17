import ApplicationServices
import ImrseCore
import XCTest
@testable import ImrseMac

final class DocumentContextFailureClassificationTests: XCTestCase {
    func testNoValueStatusClassifiesOnlyUnexpectedPayloads() {
        XCTAssertNil(SelectionTargetContextValidation.documentFailure(status: .noValue, value: nil))
        XCTAssertEqual(
            SelectionTargetContextValidation.documentFailure(status: .noValue, value: "unexpected" as CFString),
            .unexpectedNoValuePayload
        )
    }

    func testUnsupportedAttributeClassifiesAsAttributeUnsupported() {
        XCTAssertEqual(
            SelectionTargetContextValidation.documentFailure(status: .attributeUnsupported, value: nil),
            .attributeUnsupported
        )
    }

    func testMissingPayloadClassifiesAsMissingValue() {
        XCTAssertEqual(
            SelectionTargetContextValidation.documentFailure(status: .success, value: nil),
            .missingValue
        )
    }

    func testNonStringPayloadClassifiesAsUnexpectedValueType() {
        XCTAssertEqual(
            SelectionTargetContextValidation.documentFailure(status: .success, value: kCFBooleanTrue),
            .unexpectedValueType
        )
    }

    func testEmptyPayloadClassifiesAsEmptyValue() {
        XCTAssertEqual(
            SelectionTargetContextValidation.documentFailure(status: .success, value: "" as CFString),
            .emptyValue
        )
    }

    func testPayloadLengthClassifiesOnlyValuesOverTheLimit() {
        let withinLimit = String(
            repeating: "x",
            count: SelectionTargetContextValidation.maximumDocumentUTF16Length
        )
        XCTAssertNil(SelectionTargetContextValidation.documentFailure(status: .success, value: withinLimit as CFString))
        XCTAssertEqual(
            SelectionTargetContextValidation.documentFailure(
                status: .success,
                value: (withinLimit + "x") as CFString
            ),
            .valueTooLong
        )
    }

    func testReadablePayloadAndOtherAXErrorsCarryNoDocumentFailure() {
        XCTAssertNil(SelectionTargetContextValidation.documentFailure(
            status: .success,
            value: "document-😀" as CFString
        ))
        for status in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            XCTAssertNil(SelectionTargetContextValidation.documentFailure(status: status, value: nil))
        }
    }

    func testDetailAppearsExactlyForRefusedDocumentReads() {
        let overLimit = String(
            repeating: "x",
            count: SelectionTargetContextValidation.maximumDocumentUTF16Length + 1
        )
        let cases: [(status: AXError, value: CFTypeRef?, detail: DocumentContextFailure?)] = [
            (.noValue, nil, nil),
            (.noValue, "unexpected" as CFString, .unexpectedNoValuePayload),
            (.attributeUnsupported, nil, .attributeUnsupported),
            (.success, nil, .missingValue),
            (.success, kCFBooleanTrue, .unexpectedValueType),
            (.success, "" as CFString, .emptyValue),
            (.success, overLimit as CFString, .valueTooLong),
            (.success, "document-😀" as CFString, nil),
            (.cannotComplete, nil, nil)
        ]

        for (status, value, detail) in cases {
            XCTAssertEqual(SelectionTargetContextValidation.documentFailure(status: status, value: value), detail)
            switch SelectionTargetContextValidation.documentRead(status: status, value: value) {
            case .context:
                XCTAssertNil(detail)
            case .failed(.documentContextUnavailable):
                XCTAssertNotNil(detail)
            case let .failed(reason):
                XCTAssertNil(detail, "\(reason) must not carry document-context detail")
            }
        }
    }

    @MainActor
    func testFreshAccessHasNoDocumentContextFailure() {
        XCTAssertNil(MacSelectionAccess().lastDocumentContextFailure)
    }
}
