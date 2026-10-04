import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenAICompatibleProviderTests: XCTestCase {
    @MainActor
    func testReportsModelUsageAndDocumentedOpenRouterCostFromSuccessfulFrame() async throws {
        let body = #"data: {"model":"openai/gpt-6.1","choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14,"cost":0.00014}}"# + "\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        )
        let reports = ResponseMetadataReports()
        let metadataCallback: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.values.append($0) }

        let output = try await collect(provider, request: request(kind: .openRouter, reportResponseMetadata: metadataCallback))

        XCTAssertEqual(output, "Done")
        XCTAssertEqual(reports.values, [ResponseMetadata(
            detectedModel: "openai/gpt-6.1",
            inputTokens: 10,
            outputTokens: 4,
            totalTokens: 14,
            costUSD: 0.00014
        )])
    }

    @MainActor
    func testDoesNotAssumeCostCurrencyForGenericCompatibleProvider() async throws {
        let body = #"data: {"model":"served-model","choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14,"cost":0.00014}}"# + "\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        )
        let reports = ResponseMetadataReports()
        let metadataCallback: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.values.append($0) }

        let output = try await collect(provider, request: request(reportResponseMetadata: metadataCallback))

        XCTAssertEqual(output, "Done")
        XCTAssertEqual(reports.values, [ResponseMetadata(
            detectedModel: "served-model",
            inputTokens: 10,
            outputTokens: 4,
            totalTokens: 14
        )])
    }

    @MainActor
    func testTailUsageAfterStopIsUnavailableWithoutChangingCompletion() async throws {
        let body = [
            #"data: {"model":"openai/gpt-6.1","choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14,"cost":0.00014}}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n") + "\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        )
        let reports = ResponseMetadataReports()
        let metadataCallback: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.values.append($0) }

        let output = try await collect(provider, request: request(kind: .openRouter, reportResponseMetadata: metadataCallback))

        XCTAssertEqual(output, "Done")
        XCTAssertEqual(reports.values, [ResponseMetadata(detectedModel: "openai/gpt-6.1")])
    }

    @MainActor
    func testStrictTerminationAccountsForTrailingUsageBeforeDone() async throws {
        let body = [
            #"data: {"model":"openai/gpt-6.1","choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14,"cost":0.00014}}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n") + "\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)])),
            requireSuccessfulStreamTerminator: true
        )
        let reports = ResponseMetadataReports()
        let metadataCallback: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.values.append($0) }

        let output = try await collect(provider, request: request(kind: .openRouter, reportResponseMetadata: metadataCallback))

        XCTAssertEqual(output, "Done")
        XCTAssertEqual(reports.values, [ResponseMetadata(
            detectedModel: "openai/gpt-6.1",
            inputTokens: 10,
            outputTokens: 4,
            totalTokens: 14,
            costUSD: 0.00014
        )])
    }

    func testStrictTerminationRequiresBothStopAndDone() async throws {
        let bodies = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n"
        ]

        for body in bodies {
            let provider = OpenAICompatibleProvider(
                credentials: StubCredentials(value: "test-key"),
                transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)])),
                requireSuccessfulStreamTerminator: true
            )
            await assertError(.interruptedStream) {
                _ = try await collect(provider, request: request())
            }
        }
    }

    func testStrictTerminationRejectsContentAfterStop() async throws {
        let body = [
            #"data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[{"delta":{"content":"late"},"finish_reason":null}]}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n") + "\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)])),
            requireSuccessfulStreamTerminator: true
        )

        await assertError(.interruptedStream) {
            _ = try await collect(provider, request: request())
        }
    }

    func testStrictTerminationRejectsErrorAfterStop() async throws {
        let body = [
            #"data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}"#,
            #"data: {"error":{"message":"late failure"}}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n") + "\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)])),
            requireSuccessfulStreamTerminator: true
        )

        await assertError(.server) {
            _ = try await collect(provider, request: request())
        }
    }

    func testMultipleChoicesCannotBeCombinedIntoOneReplacement() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"first\"},\"finish_reason\":\"stop\"},{\"delta\":{\"content\":\"second\"},\"finish_reason\":\"stop\"}]}\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        )
        await assertError(.malformedResponse) {
            _ = try await collect(provider, request: request())
        }
    }

    func testStreamsChunksAndRequiresExplicitCompletion() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"world\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        let transport = StubTransport(exchange: exchange(status: 200, chunks: body.utf8.map { Data([$0]) }))
        let provider = OpenAICompatibleProvider(credentials: StubCredentials(value: "test-key"), transport: transport)

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "Hello world")
        let captured = await transport.captured()
        XCTAssertEqual(captured?.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(captured?.request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(captured?.request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        let payload = try XCTUnwrap(captured?.request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["rewrite", "input"])
    }

    func testReasoningEffortUsesAdvertisedFormatAndClearsUnsupportedSelections() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\"}]}\n\n"
        let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1")!
        let cases: [(ProviderKind, String, String?, ReasoningEffortCapabilities?, [String: Any])] = [
            (
                .openRouter,
                "model-1",
                "high",
                ReasoningEffortCapabilities(
                    endpoint: openRouterEndpoint,
                    model: "model-1",
                    supportedEfforts: ["high", "low"],
                    requestFormat: .chatCompletionsObject
                ),
                ["effort": "high"]
            ),
            (
                .compatible,
                "model-1",
                "low",
                ReasoningEffortCapabilities(
                    endpoint: URL(string: "https://api.example.com/v1")!,
                    model: "model-1",
                    supportedEfforts: ["high", "low"],
                    requestFormat: .chatCompletionsField
                ),
                ["reasoning_effort": "low"]
            ),
            (
                .openRouter,
                "model-1",
                nil,
                ReasoningEffortCapabilities(
                    endpoint: openRouterEndpoint,
                    model: "model-1",
                    supportedEfforts: ["high", "low"],
                    requestFormat: .chatCompletionsObject
                ),
                [:]
            ),
            (
                .openRouter,
                "model-1",
                "xhigh",
                ReasoningEffortCapabilities(
                    endpoint: openRouterEndpoint,
                    model: "model-1",
                    supportedEfforts: ["high", "low"],
                    requestFormat: .chatCompletionsObject
                ),
                [:]
            ),
            (
                .openRouter,
                "preset-model-override",
                "high",
                ReasoningEffortCapabilities(
                    endpoint: openRouterEndpoint,
                    model: "model-1",
                    supportedEfforts: ["high", "low"],
                    requestFormat: .chatCompletionsObject
                ),
                [:]
            )
        ]

        for (kind, model, effort, capabilities, expected) in cases {
            let transport = StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
            let provider = OpenAICompatibleProvider(credentials: StubCredentials(value: "test-key"), transport: transport)
            _ = try await collect(
                provider,
                request: request(
                    model: model,
                    kind: kind,
                    reasoningEffort: effort,
                    reasoningEffortCapabilities: capabilities
                )
            )
            let captured = await transport.captured()
            let payload = try XCTUnwrap(captured?.request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            if kind == .compatible && !expected.isEmpty {
                XCTAssertEqual(json["reasoning_effort"] as? String, expected["reasoning_effort"] as? String)
                XCTAssertNil(json["reasoning"])
            } else if !expected.isEmpty {
                XCTAssertEqual(json["reasoning"] as? [String: String], expected as? [String: String])
                XCTAssertNil(json["reasoning_effort"])
            } else {
                XCTAssertNil(json["reasoning"])
                XCTAssertNil(json["reasoning_effort"])
            }
        }
    }

    func testFinishReasonAloneIsExplicitCompletion() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\"}]}\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        )

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "Done")
    }

    func testNonStopFinishReasonsNeverCompletePartialOutput() async throws {
        for reason in ["length", "content_filter", "tool_calls", "function_call"] {
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"\(reason)\"}]}\n\n"
            let provider = OpenAICompatibleProvider(
                credentials: StubCredentials(value: "test-key"),
                transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
            )
            await assertError(.interruptedStream) {
                _ = try await collect(provider, request: request())
            }
        }
    }

    func testTruncatedStreamDoesNotReportSuccess() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        )

        await assertError(.interruptedStream) {
            _ = try await collect(provider, request: request())
        }
    }

    func testMalformedFramesAndOversizedOutputFailClosed() async throws {
        let malformed = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data("data: not-json\n\n".utf8)]))
        )
        await assertError(.malformedResponse) {
            _ = try await collect(malformed, request: request())
        }

        let oversized = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"12345\"},\"finish_reason\":\"stop\"}]}\n\n".utf8)])),
            maximumOutputBytes: 4
        )
        await assertError(.outputTooLarge) {
            _ = try await collect(oversized, request: request())
        }
    }

    func testHTTPStatusesNetworkTimeoutAndMissingCredentialsMapToCoreErrors() async throws {
        for (status, error) in [(401, ImrseError.authentication), (403, .authentication), (429, .rateLimited), (408, .timeout), (504, .timeout), (500, .server), (400, .invalidConfiguration)] {
            let provider = OpenAICompatibleProvider(
                credentials: StubCredentials(value: "test-key"),
                transport: StubTransport(exchange: exchange(status: status, chunks: []))
            )
            await assertError(error) {
                _ = try await collect(provider, request: request())
            }
        }

        let offline = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(error: URLError(.cannotConnectToHost))
        )
        await assertError(.network) {
            _ = try await collect(offline, request: request())
        }

        let timedOut = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(error: URLError(.timedOut))
        )
        await assertError(.timeout) {
            _ = try await collect(timedOut, request: request())
        }

        let missingKey = OpenAICompatibleProvider(
            credentials: StubCredentials(value: nil),
            transport: StubTransport(exchange: exchange(status: 200, chunks: []))
        )
        await assertError(.missingCredentials) {
            _ = try await collect(missingKey, request: request())
        }
    }

    func testCredentialHeadersRejectControlsAndEnforceMaximumLength() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n"
        for credential in ["key\r\nInjected: yes", "key\tvalue", "key\u{7f}", String(repeating: "a", count: 4_097)] {
            let transport = StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
            let provider = OpenAICompatibleProvider(credentials: StubCredentials(value: credential), transport: transport)
            await assertError(.authentication) {
                _ = try await collect(provider, request: request())
            }
            let captured = await transport.captured()
            XCTAssertNil(captured)
        }

        let maximumLengthCredential = String(repeating: "a", count: 4_096)
        let transport = StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        let provider = OpenAICompatibleProvider(credentials: StubCredentials(value: maximumLengthCredential), transport: transport)
        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "ok")
        let captured = await transport.captured()
        XCTAssertEqual(captured?.request.value(forHTTPHeaderField: "Authorization")?.utf8.count, 4_103)
    }

    func testMissingModelReturnsSpecificErrorBeforeGenericValidation() async throws {
        let transport = StubTransport(exchange: exchange(status: 200, chunks: []))
        let provider = OpenAICompatibleProvider(credentials: StubCredentials(value: "test-key"), transport: transport)

        await assertError(.missingModel) {
            _ = try await collect(provider, request: request(model: " "))
        }
        let captured = await transport.captured()
        XCTAssertNil(captured)
    }

    func testLocalOnlyRejectsCloudAndPassesLocalNetworkPolicy() async throws {
        let cloud = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(exchange: exchange(status: 200, chunks: []))
        )
        await assertError(.localModelUnavailable) {
            _ = try await collect(cloud, request: request(localOnly: true))
        }

        let localRequest = TransformationRequest(
            text: "input",
            instruction: "rewrite",
            provider: ProviderConfiguration(
                id: "local",
                name: "Local",
                kind: .compatible,
                endpoint: URL(string: "http://127.0.0.1:1234/v1")!,
                model: "local-model",
                requiresCredential: false
            ),
            localOnly: true
        )
        let localBody = "data: {\"choices\":[{\"delta\":{\"content\":\"local\"},\"finish_reason\":\"stop\"}]}\n\n"
        let localTransport = StubTransport(exchange: exchange(status: 200, chunks: [Data(localBody.utf8)]))
        let localProvider = OpenAICompatibleProvider(credentials: StubCredentials(value: nil), transport: localTransport)
        let output = try await collect(localProvider, request: localRequest)
        XCTAssertEqual(output, "local")
        let captured = await localTransport.captured()
        XCTAssertEqual(captured?.localOnly, true)
    }

    func testCancellationMapsToCancelled() async throws {
        let provider = OpenAICompatibleProvider(
            credentials: StubCredentials(value: "test-key"),
            transport: StubTransport(error: CancellationError())
        )
        await assertError(.cancelled) {
            _ = try await collect(provider, request: request())
        }
    }

    private func request(
        localOnly: Bool = false,
        model: String = "model-1",
        kind: ProviderKind = .compatible,
        reportResponseMetadata: (@MainActor @Sendable (ResponseMetadata) -> Void)? = nil,
        reasoningEffort: String? = nil,
        reasoningEffortCapabilities: ReasoningEffortCapabilities? = nil
    ) -> TransformationRequest {
        TransformationRequest(
            text: "input",
            instruction: "rewrite",
            provider: ProviderConfiguration(
                id: "compatible",
                name: "Compatible",
                kind: kind,
                endpoint: URL(string: kind == .openRouter ? "https://openrouter.ai/api/v1" : "https://api.example.com/v1")!,
                model: model,
                reasoningEffort: reasoningEffort,
                reasoningEffortCapabilities: reasoningEffortCapabilities
            ),
            localOnly: localOnly,
            reportResponseMetadata: reportResponseMetadata
        )
    }
}

@MainActor
private final class ResponseMetadataReports {
    var values: [ResponseMetadata] = []
}

private struct CapturedRequest: Sendable {
    let request: URLRequest
    let localOnly: Bool
}

private actor StubTransport: StreamingHTTPTransport {
    private let result: Result<HTTPExchange, any Error>
    private var lastCaptured: CapturedRequest?

    init(exchange: HTTPExchange) { result = .success(exchange) }
    init(error: any Error) { result = .failure(error) }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        lastCaptured = CapturedRequest(request: request, localOnly: localOnly)
        return try result.get()
    }

    func captured() -> CapturedRequest? { lastCaptured }
}

private actor StubCredentials: CredentialStore {
    private let value: String?
    init(value: String?) { self.value = value }
    func credential(for providerID: String) async throws -> String? { value }
    func setCredential(_ value: String?, for providerID: String) async throws {}
}

private func exchange(status: Int, chunks: [Data]) -> HTTPExchange {
    HTTPExchange(statusCode: status, headers: ["Content-Type": "text/event-stream"], body: dataStream(chunks))
}

private func dataStream(_ chunks: [Data]) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}

private func collect(_ provider: OpenAICompatibleProvider, request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    var output = ""
    for try await piece in stream { output += piece }
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
