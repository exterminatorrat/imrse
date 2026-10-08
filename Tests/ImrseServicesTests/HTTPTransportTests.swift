import Foundation
import XCTest
import ImrseCore
@testable import ImrseServices
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPTransportTests: XCTestCase {
    func testDroppedTransportChunkInterruptsStreamInsteadOfReportingOversizedOutput() async throws {
        let response = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let driver = URLSessionStreamDriver(configuration: .ephemeral, body: response.continuation)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1/unused")!)

        driver.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x61, count: 16_384))

        var received = [Data]()
        do {
            for try await chunk in response.stream { received.append(chunk) }
            XCTFail("A dropped transport chunk must fail the stream")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .interruptedStream)
        }
        XCTAssertEqual(received, [Data(repeating: 0x61, count: 8_192)])
    }
}
