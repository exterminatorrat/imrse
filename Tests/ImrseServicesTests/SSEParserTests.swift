import XCTest
@testable import ImrseServices
import ImrseCore

final class SSEParserTests: XCTestCase {
    func testIncrementalCRLFAndMultipleDataLines() throws {
        var parser = SSEParser(maximumEventBytes: 128)
        let bytes = Array(": keepalive\r\ndata: {\"choices\":\r\ndata: []}\r\n\r\ndata: [DONE]\r\n\r\n".utf8)
        var events: [String] = []
        for byte in bytes {
            events += try parser.append(Data([byte]))
        }
        events += try parser.finish()

        XCTAssertEqual(events, ["{\"choices\":\n[]}", "[DONE]"])
    }

    func testSupportsBareCRAndLFSeparators() throws {
        var parser = SSEParser(maximumEventBytes: 128)
        let first = try parser.append(Data("data: one\r\rdata: two\n\n".utf8))
        XCTAssertEqual(first, ["one", "two"])
    }

    func testRejectsOversizedEventsAndInvalidUTF8() {
        var parser = SSEParser(maximumEventBytes: 4)
        XCTAssertThrowsError(try parser.append(Data("data: too long\n\n".utf8))) {
            XCTAssertEqual($0 as? ImrseError, .outputTooLarge)
        }

        var invalidParser = SSEParser(maximumEventBytes: 16)
        XCTAssertThrowsError(try invalidParser.append(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0x0A, 0x0A]))) {
            XCTAssertEqual($0 as? ImrseError, .malformedResponse)
        }
    }
}
