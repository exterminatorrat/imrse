import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AnthropicTextProviderTests: XCTestCase {
    func testStreamsOnlyTextAndRequiresNativeMessagesTerminalEvents() async throws {
        let transport = StubTransport(events: [
            #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"manual-model-id","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private reasoning"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"world"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":4}}"#,
            #"{"type":"message_stop"}"#
        ])
        let provider = AnthropicTextProvider(credentials: StubCredentials(value: "test-api-key"), transport: transport)

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "Hello world")
        let captured = await transport.captured()
        let urlRequest = try XCTUnwrap(captured)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "test-api-key")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "manual-model-id")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["system"] as? String, "rewrite")
        XCTAssertEqual(json["messages"] as? [[String: String]], [["role": "user", "content": "selected"]])
    }

    func testAcceptsStopSequenceAsSuccessfulCompletion() async throws {
        let provider = AnthropicTextProvider(
            credentials: StubCredentials(value: "key"),
            transport: StubTransport(events: successfulEvents(stopReason: "stop_sequence"))
        )
        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "done")
    }

    func testAllowsMultipleMessageDeltaEventsBeforeTheTerminalMarker() async throws {
        var events = successfulEvents(stopReason: "end_turn")
        events.insert(#"{"type":"message_delta","delta":{"stop_reason":null},"usage":{"output_tokens":2}}"#, at: events.count - 1)
        let provider = AnthropicTextProvider(credentials: StubCredentials(value: "key"), transport: StubTransport(events: events))

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "done")
    }

    func testRejectsMissingTerminalAndNonSuccessfulStopReasons() async {
        let incomplete = [
            messageStart,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#
        ]
        let maxTokens = successfulEvents(stopReason: "max_tokens")
        let missingMessageDelta = [
            messageStart,
            #"{"type":"message_stop"}"#
        ]
        for events in [incomplete, maxTokens, missingMessageDelta] {
            let provider = AnthropicTextProvider(credentials: StubCredentials(value: "key"), transport: StubTransport(events: events))
            await assertError(.interruptedStream) {
                _ = try await collect(provider, request: request())
            }
        }
    }

    func testRejectsToolBlocksErrorsMalformedEventsAndReasoningOnlyOutput() async {
        let tool = [
            messageStart,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"search","input":{}}}"#
        ]
        let error = [#"{"type":"error","error":{"type":"overloaded_error","message":"unavailable"}}"#]
        let thinkingOnly = [
            messageStart,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#
        ]

        await assertError(.interruptedStream) {
            _ = try await collect(AnthropicTextProvider(credentials: StubCredentials(value: "key"), transport: StubTransport(events: tool)), request: request())
        }
        await assertError(.server) {
            _ = try await collect(AnthropicTextProvider(credentials: StubCredentials(value: "key"), transport: StubTransport(events: error)), request: request())
        }
        await assertError(.emptyOutput) {
            _ = try await collect(AnthropicTextProvider(credentials: StubCredentials(value: "key"), transport: StubTransport(events: thinkingOnly)), request: request())
        }
        await assertError(.malformedResponse) {
            _ = try await collect(AnthropicTextProvider(credentials: StubCredentials(value: "key"), transport: StubTransport(raw: "data: not-json\n\n")), request: request())
        }
    }

    func testEnforcesCredentialAndOutputLimits() async {
        await assertError(.missingCredentials) {
            _ = try await collect(
                AnthropicTextProvider(credentials: StubCredentials(value: nil), transport: StubTransport(events: successfulEvents(stopReason: "end_turn"))),
                request: request()
            )
        }

        let largeText = String(repeating: "x", count: 1_048_577)
        await assertError(.selectionTooLarge) {
            _ = try await collect(
                AnthropicTextProvider(credentials: StubCredentials(value: "key"), transport: StubTransport(events: successfulEvents(stopReason: "end_turn"))),
                request: request(text: largeText)
            )
        }

        let provider = AnthropicTextProvider(
            credentials: StubCredentials(value: "key"),
            transport: StubTransport(events: successfulEvents(stopReason: "end_turn", text: "12345")),
            maximumOutputBytes: 4
        )
        await assertError(.outputTooLarge) { _ = try await collect(provider, request: request()) }
    }

    func testCancellingTheConsumerCancelsTheUnderlyingHTTPExchange() async throws {
        let cancellation = CancellationTracker()
        let textReceived = TestSignal()
        let provider = AnthropicTextProvider(
            credentials: StubCredentials(value: "key"),
            transport: PendingTransport(cancellation: cancellation)
        )
        let transformation = request()
        let consumer = Task {
            do {
                let stream = try await provider.stream(transformation)
                for try await delta in stream {
                    if delta == "partial" { await textReceived.signal() }
                }
            } catch {}
        }

        await textReceived.wait()
        consumer.cancel()
        await consumer.value
        for _ in 0..<100 {
            if await cancellation.wasCancelled() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let exchangeWasCancelled = await cancellation.wasCancelled()
        XCTAssertTrue(exchangeWasCancelled)
    }

    private func request(text: String = "selected") -> TransformationRequest {
        TransformationRequest(
            text: text,
            instruction: "rewrite",
            provider: ProviderConfiguration(
                id: "anthropic",
                name: "Anthropic",
                kind: .anthropic,
                endpoint: URL(string: "https://api.anthropic.com/v1")!,
                model: "manual-model-id"
            )
        )
    }
}

private struct StubTransport: StreamingHTTPTransport {
    private let responseBody: Data
    private let capture: CapturedRequest

    init(events: [String]) {
        responseBody = Data(events.map { "data: \($0)\n\n" }.joined().utf8)
        capture = CapturedRequest()
    }

    init(raw: String) {
        responseBody = Data(raw.utf8)
        capture = CapturedRequest()
    }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        await capture.set(request)
        return HTTPExchange(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(responseBody)
            continuation.finish()
        })
    }

    func captured() async -> URLRequest? { await capture.get() }
}

private actor CapturedRequest {
    private var value: URLRequest?
    func set(_ request: URLRequest) { value = request }
    func get() -> URLRequest? { value }
}

private actor StubCredentials: CredentialStore {
    private let value: String?

    init(value: String?) { self.value = value }

    func credential(for providerID: String) async throws -> String? { value }
    func setCredential(_ value: String?, for providerID: String) async throws {}
}

private struct PendingTransport: StreamingHTTPTransport {
    let cancellation: CancellationTracker

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        let body = AsyncThrowingStream<Data, any Error>.makeStream()
        let events = [
            messageStart,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#
        ]
        body.continuation.yield(Data(events.map { "data: \($0)\n\n" }.joined().utf8))
        let continuation = body.continuation
        return HTTPExchange(statusCode: 200, body: body.stream, cancel: {
            Task {
                await cancellation.recordCancellation()
                continuation.finish(throwing: CancellationError())
            }
        })
    }
}

private actor CancellationTracker {
    private var cancelled = false
    func recordCancellation() { cancelled = true }
    func wasCancelled() -> Bool { cancelled }
}

private actor TestSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func successfulEvents(stopReason: String, text: String = "done") -> [String] {
    [
        messageStart,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"}}"#,
        #"{"type":"message_stop"}"#
    ]
}

private let messageStart = #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"manual-model-id","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}}"#

private func collect(_ provider: any TextProvider, request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    var output = ""
    for try await delta in stream { output += delta }
    return output
}

private func assertError(
    _ expected: ImrseError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ImrseError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), received \(error)", file: file, line: line)
    }
}
