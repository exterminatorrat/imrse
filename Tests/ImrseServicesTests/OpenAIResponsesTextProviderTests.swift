import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenAIResponsesTextProviderTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testReportsProviderModelAndUsageFromCompletedResponse() async throws {
        let provider = try await provider(body: [
            #"data: {"type":"response.completed","response":{"status":"completed","model":"gpt-6.1-sol-2026-04-01","usage":{"input_tokens":12,"output_tokens":7,"total_tokens":19},"output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer"}]}]}}"# + "\n\n"
        ].joined())
        let reports = ResponseMetadataReports()
        let metadataCallback: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.values.append($0) }

        let output = try await collect(provider, request: request(reportResponseMetadata: metadataCallback))

        XCTAssertEqual(output, "answer")
        XCTAssertEqual(reports.values, [ResponseMetadata(
            detectedModel: "gpt-6.1-sol-2026-04-01",
            inputTokens: 12,
            outputTokens: 7,
            totalTokens: 19
        )])
    }

    @MainActor
    func testInvalidUsageFieldsStayUnavailableWithoutFailingCompletedResponse() async throws {
        let provider = try await provider(body: [
            #"data: {"type":"response.completed","response":{"status":"completed","model":"gpt-6.1-sol","usage":{"input_tokens":true,"output_tokens":2.5,"total_tokens":9223372036854775808},"output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer"}]}]}}"# + "\n\n"
        ].joined())
        let reports = ResponseMetadataReports()
        let metadataCallback: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.values.append($0) }

        let output = try await collect(provider, request: request(reportResponseMetadata: metadataCallback))

        XCTAssertEqual(output, "answer")
        XCTAssertEqual(reports.values, [ResponseMetadata(detectedModel: "gpt-6.1-sol")])
    }

    @MainActor
    func testMissingMetadataDoesNotFailCompletedResponseOrReportConfiguredModel() async throws {
        let provider = try await provider(body: [
            #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer"}]}]}}"# + "\n\n"
        ].joined())
        let reports = ResponseMetadataReports()
        let metadataCallback: @MainActor @Sendable (ResponseMetadata) -> Void = { reports.values.append($0) }

        let output = try await collect(provider, request: request(reportResponseMetadata: metadataCallback))

        XCTAssertEqual(output, "answer")
        XCTAssertTrue(reports.values.isEmpty)
    }

    func testCompletedResponsesUseOfficialBodyAndKeepInstructionsOutOfSystemInput() async throws {
        let credentials = MemoryCredentials()
        try await credentials.setCredential(sessionJSON(), for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        let body = [
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_commentary\",\"output_index\":0,\"delta\":\"aside\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_final\",\"output_index\":1,\"delta\":\"Hello \"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_final\",\"output_index\":1,\"delta\":\"world\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"id\":\"msg_commentary\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"aside\"}]},{\"id\":\"msg_final\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello world\"}]}]}}\n\n"
        ].joined()
        let transport = StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
        let client = OpenAIAccountClient(credentials: credentials, transport: StubTransport(exchange: exchange(status: 200, chunks: [])))
        let provider = OpenAIResponsesTextProvider(accountClient: client, transport: transport)

        let output = try await collect(provider, request: request())

        XCTAssertEqual(output, "Hello world")
        let capturedRequest = await transport.captured()
        let captured = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(captured.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let payload = try XCTUnwrap(captured.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["model", "instructions", "input", "store", "stream"])
        XCTAssertEqual(json["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(json["instructions"] as? String, "rewrite")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[0]["content"] as? String, "selected text")
    }

    func testReasoningEffortUsesAdvertisedSelectionOnlyForMatchingAccountModel() async throws {
        let endpoint = URL(string: "https://api.openai.com/v1")!
        let body = #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer"}]}]}}"# + "\n\n"
        let cases: [(String, String?, ReasoningEffortCapabilities?, String?)] = [
            (
                "gpt-6.1-sol",
                "high",
                ReasoningEffortCapabilities(
                    endpoint: endpoint,
                    model: "gpt-6.1-sol",
                    supportedEfforts: ["high", "medium"],
                    requestFormat: .responsesObject
                ),
                "high"
            ),
            (
                "gpt-6.1-sol",
                "xhigh",
                ReasoningEffortCapabilities(
                    endpoint: endpoint,
                    model: "gpt-6.1-sol",
                    supportedEfforts: ["high", "medium"],
                    requestFormat: .responsesObject
                ),
                nil
            ),
            (
                "preset-model-override",
                "high",
                ReasoningEffortCapabilities(
                    endpoint: endpoint,
                    model: "gpt-6.1-sol",
                    supportedEfforts: ["high", "medium"],
                    requestFormat: .responsesObject
                ),
                nil
            ),
            (
                "gpt-6.1-sol",
                "high",
                ReasoningEffortCapabilities(
                    endpoint: endpoint,
                    model: "gpt-6.1-sol",
                    supportedEfforts: ["high", "medium"],
                    requestFormat: .chatCompletionsField
                ),
                nil
            )
        ]

        for (modelID, effort, capabilities, expectedEffort) in cases {
            let credentials = MemoryCredentials()
            try await credentials.setCredential(sessionJSON(), for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
            let accountClient = OpenAIAccountClient(credentials: credentials, transport: StubTransport(exchange: exchange(status: 200, chunks: [])))
            let transport = StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)]))
            let provider = OpenAIResponsesTextProvider(accountClient: accountClient, transport: transport)

            _ = try await collect(
                provider,
                request: request(
                    model: modelID,
                    reasoningEffort: effort,
                    reasoningEffortCapabilities: capabilities
                )
            )

            let capturedRequest = await transport.captured()
            let payload = try XCTUnwrap(capturedRequest?.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            XCTAssertEqual((json["reasoning"] as? [String: String])?["effort"], expectedEffort)
        }
    }

    func testOnlyResponseCompletedEndsSuccessfully() async throws {
        let cases: [(String, ImrseError)] = [
            (#"data: {"type":"response.failed","response":{"error":{"message":"synthetic-response-secret"}}}"# + "\n\n", .server),
            (#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"# + "\n\n", .authentication),
            (#"data: {"type":"response.incomplete","response":{"status":"incomplete"}}"# + "\n\n", .interruptedStream),
            (#"data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"partial"}"# + "\n\n", .interruptedStream),
            (#"data: {"type":"response.completed"}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"completed"}}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"incomplete","output":[]}}"# + "\n\n", .interruptedStream),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"incomplete","content":[]}]}}"# + "\n\n", .interruptedStream),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":"invalid"}}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n", .emptyOutput),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":false}]}]}}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"phase":false,"delta":"text"}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","phase":"unknown","content":[{"type":"output_text","text":"text"}]}]}}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","phase":false,"content":[{"type":"output_text","text":"text"}]}]}}"# + "\n\n", .malformedResponse),
            ("data: [DONE]\n\n", .interruptedStream)
        ]
        for (event, expected) in cases {
            let provider = try await provider(body: event)
            do {
                _ = try await collect(provider, request: request())
                XCTFail("Expected \(expected)")
            } catch let error as ImrseError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(String(describing: error).contains("synthetic-response-secret"))
            }
        }
    }

    func testUsesOnlyFinalAnswerPhaseFromCompletedOutput() async throws {
        let provider = try await provider(body: [
            #"data: {"type":"response.output_text.delta","item_id":"msg_commentary","output_index":0,"delta":"ignore this"}"# + "\n\n",
            #"data: {"type":"response.output_text.delta","item_id":"msg_analysis","output_index":1,"delta":"ignore that"}"# + "\n\n",
            #"data: {"type":"response.output_text.delta","item_id":"msg_final","output_index":2,"delta":"answer"}"# + "\n\n",
            #"data: {"type":"response.completed","response":{"status":"completed","output":[{"id":"msg_commentary","type":"message","role":"assistant","status":"completed","phase":"commentary","content":[{"type":"output_text","text":"aside"}]},{"id":"msg_analysis","type":"message","role":"assistant","status":"completed","phase":"analysis","content":[{"type":"output_text","text":"reasoning"}]},{"id":"msg_final","type":"message","role":"assistant","status":"completed","phase":"final_answer","content":[{"type":"output_text","text":"answer"}]}]}}"# + "\n\n"
        ].joined())

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "answer")
    }

    func testCompletedEmptyOutputUsesFinalOutputItemDoneContent() async throws {
        let text = String(repeating: "x", count: 40)
        let provider = try await provider(body: [
            #"data: {"type":"response.output_text.delta","item_id":"msg_final","output_index":0,"delta":"\#(text)"}"# + "\n\n",
            outputItemDone(outputIndex: 0, itemID: "msg_final", text: text),
            #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
        ].joined())

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, text)
        XCTAssertEqual(output.utf8.count, 40)
    }

    func testOutputItemDoneFallbackOrdersItemsDeduplicatesAndIgnoresNonFinalPhases() async throws {
        let provider = try await provider(body: [
            outputItemDone(outputIndex: 1, itemID: "msg_second", text: "second"),
            outputItemDone(outputIndex: 0, itemID: "msg_first", text: "first"),
            outputItemDone(outputIndex: 0, itemID: "msg_first", text: "first"),
            outputItemDone(outputIndex: 2, itemID: "msg_commentary", phaseJSON: #""commentary""#, text: "aside"),
            outputItemDone(outputIndex: 3, itemID: "msg_analysis", phaseJSON: #""analysis""#, text: "reasoning"),
            #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
        ].joined())

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "firstsecond")
    }

    func testOutputItemDoneFallbackTreatsAbsentAndNullPhasesAsLegacyFinal() async throws {
        let provider = try await provider(body: [
            outputItemDone(outputIndex: 0, itemID: "msg_absent", phaseJSON: nil, text: "legacy "),
            outputItemDone(outputIndex: 0, itemID: "msg_absent", phaseJSON: "null", text: "legacy "),
            outputItemDone(outputIndex: 1, itemID: "msg_null", phaseJSON: "null", text: "answer"),
            #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
        ].joined())

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "legacy answer")
    }

    func testRepeatedOutputItemDoneMustKeepItsClassification() async throws {
        let finalAnswer = outputItemDone(outputIndex: 0, itemID: "msg_final", text: "answer")
        let reasoning = #"data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_final","type":"reasoning"}}"# + "\n\n"
        let cases = [
            (finalAnswer, outputItemDone(outputIndex: 0, itemID: "msg_final", phaseJSON: #""analysis""#, text: "reasoning")),
            (finalAnswer, outputItemDone(outputIndex: 0, itemID: "msg_final", phaseJSON: #""commentary""#, text: "aside")),
            (finalAnswer, reasoning),
            (outputItemDone(outputIndex: 0, itemID: "msg_final", phaseJSON: #""analysis""#, text: "reasoning"), finalAnswer),
            (outputItemDone(outputIndex: 0, itemID: "msg_final", phaseJSON: #""commentary""#, text: "aside"), finalAnswer),
            (reasoning, finalAnswer)
        ]

        for (first, second) in cases {
            let provider = try await provider(body: first + second +
                #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
            )
            let stream = try await provider.stream(request())
            var emitted = ""

            do {
                for try await piece in stream { emitted.append(piece) }
                XCTFail("Expected contradictory output item classification")
            } catch let error as ImrseError {
                XCTAssertEqual(error, .malformedResponse)
            }

            XCTAssertTrue(emitted.isEmpty)
        }
    }

    func testOutputItemDoneFallbackRequiresCompletedResponseWithEmptyOutput() async throws {
        let doneItem = outputItemDone(outputIndex: 0, itemID: "msg_final", text: "fallback")
        let cases: [(String, ImrseError)] = [
            (#"data: {"type":"response.completed","response":{"status":"completed"}}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":"invalid"}}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":false}]}]}}"# + "\n\n", .malformedResponse),
            (#"data: {"type":"response.completed","response":{"status":"incomplete","output":[]}}"# + "\n\n", .interruptedStream),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","phase":"analysis","content":[{"type":"output_text","text":"reasoning"}]}]}}"# + "\n\n", .emptyOutput),
            (#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":"declined"}]}]}}"# + "\n\n", .emptyOutput),
            (#"data: {"type":"response.failed","error":{"message":"synthetic-event-secret"}}"# + "\n\n", .server),
            (#"data: {"type":"response.incomplete","response":{"status":"incomplete"}}"# + "\n\n", .interruptedStream),
            ("", .interruptedStream)
        ]
        for (terminalEvent, expected) in cases {
            let provider = try await provider(body: doneItem + terminalEvent)
            let stream = try await provider.stream(request())
            var emitted = ""

            do {
                for try await piece in stream { emitted.append(piece) }
                XCTFail("Expected \(expected)")
            } catch let error as ImrseError {
                XCTAssertEqual(error, expected)
            }

            XCTAssertTrue(emitted.isEmpty)
        }

        let terminalProvider = try await provider(body: doneItem + [
            #"data: {"type":"response.completed","response":{"status":"completed","output":[{"id":"msg_terminal","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"terminal"}]}]}}"# + "\n\n"
        ].joined())
        let output = try await collect(terminalProvider, request: request())
        XCTAssertEqual(output, "terminal")
    }

    func testOutputIndicesRejectBooleanValuesWithoutEmittingText() async throws {
        let cases = [
            #"data: {"type":"response.output_text.delta","item_id":"msg_final","output_index":false,"delta":"answer"}"# + "\n\n",
            #"data: {"type":"response.output_item.done","output_index":false,"item":{"id":"msg_final","type":"message","role":"assistant","status":"completed","phase":"final_answer","content":[{"type":"output_text","text":"answer"}]}}"# + "\n\n"
        ]
        for event in cases {
            let provider = try await provider(body: event +
                #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
            )
            let stream = try await provider.stream(request())
            var emitted = ""
            do {
                for try await piece in stream { emitted.append(piece) }
                XCTFail("Expected malformed output index")
            } catch let error as ImrseError {
                XCTAssertEqual(error, .malformedResponse)
            }
            XCTAssertTrue(emitted.isEmpty)
        }
    }

    func testOutputItemDoneFallbackPreservesIdentityAndOutputLimits() async throws {
        let mismatchedIdentity = try await provider(body: [
            #"data: {"type":"response.output_text.delta","item_id":"msg_delta","output_index":0,"delta":"text"}"# + "\n\n",
            outputItemDone(outputIndex: 0, itemID: "msg_done", text: "text"),
            #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
        ].joined())
        do {
            _ = try await collect(mismatchedIdentity, request: request())
            XCTFail("Expected output item identity mismatch")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .malformedResponse)
        }

        let overLimit = try await provider(
            body: [
                outputItemDone(outputIndex: 1, itemID: "msg_second", text: "abc"),
                outputItemDone(outputIndex: 0, itemID: "msg_first", text: "abc"),
                #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
            ].joined(),
            maximumOutputBytes: 4
        )
        do {
            _ = try await collect(overLimit, request: request())
            XCTFail("Expected output size failure")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .outputTooLarge)
        }
    }

    func testAbsentAndNullOutputPhasesAreLegacyFinalAnswers() async throws {
        let provider = try await provider(body:
            #"data: {"type":"response.completed","response":{"status":"completed","output":[{"id":"msg_absent","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"legacy "}]},{"id":"msg_null","type":"message","role":"assistant","status":"completed","phase":null,"content":[{"type":"output_text","text":"answer"}]}]}}"# + "\n\n"
        )

        let output = try await collect(provider, request: request())
        XCTAssertEqual(output, "legacy answer")
    }

    func testDoesNotEmitDeltasBeforeCompletedOutputValidation() async throws {
        let delta = #"data: {"type":"response.output_text.delta","item_id":"msg_unverified","output_index":0,"delta":"unverified"}"# + "\n\n"
        let cases: [(String, ImrseError)] = [
            (delta + #"data: {"type":"response.completed","response":{"status":"completed"}}"# + "\n\n", .malformedResponse),
            (delta + #"data: {"type":"response.completed","response":{"status":"incomplete","output":[]}}"# + "\n\n", .interruptedStream),
            (delta + #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n", .emptyOutput)
        ]
        for (body, expected) in cases {
            let provider = try await provider(body: body)
            let stream = try await provider.stream(request())
            var emitted = ""

            do {
                for try await piece in stream { emitted.append(piece) }
                XCTFail("Expected \(expected)")
            } catch let error as ImrseError {
                XCTAssertEqual(error, expected)
            }

            XCTAssertTrue(emitted.isEmpty)
        }
    }

    func testOutputLimitAndLocalOnlyPolicyArePreserved() async throws {
        let provider = try await provider(
            body: #"data: {"type":"response.output_text.delta","item_id":"msg_large","output_index":0,"delta":"12345"}"# + "\n\n" +
                #"data: {"type":"response.completed"}"# + "\n\n",
            maximumOutputBytes: 4
        )
        do {
            _ = try await collect(provider, request: request())
            XCTFail("Expected output size failure")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .outputTooLarge)
        }

        let localRequest = TransformationRequest(
            text: "selected text",
            instruction: "rewrite",
            provider: ProviderConfiguration(
                id: "chatgpt-account",
                name: "ChatGPT",
                kind: .openAIChatGPT,
                endpoint: URL(string: "https://api.openai.com/v1")!,
                model: "gpt-6.1-sol"
            ),
            localOnly: true
        )
        do {
            _ = try await collect(provider, request: localRequest)
            XCTFail("Expected local-only rejection")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .localModelUnavailable)
        }
    }

    func testHTTPAndStreamFailuresNeverExposeResponseSecrets() async throws {
        let failedHTTP = OpenAIResponsesTextProvider(
            accountClient: try await accountClient(),
            transport: StubTransport(exchange: exchange(status: 503, chunks: [Data("synthetic-http-secret".utf8)]))
        )
        do {
            _ = try await collect(failedHTTP, request: request())
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains("synthetic-http-secret"))
        }

        let usageLimit = OpenAIResponsesTextProvider(
            accountClient: try await accountClient(),
            transport: StubTransport(exchange: exchange(
                status: 429,
                chunks: [Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","param":"input"}}"#.utf8)]
            ))
        )
        do {
            _ = try await collect(usageLimit, request: request())
            XCTFail("Expected non-transient plan usage failure")
        } catch let error as ImrseError {
            XCTAssertEqual(error, .authentication)
        }

        let failedEvent = try await provider(body: #"data: {"type":"response.failed","error":{"message":"synthetic-event-secret"}}"# + "\n\n")
        do {
            _ = try await collect(failedEvent, request: request())
            XCTFail("Expected terminal failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains("synthetic-event-secret"))
        }
    }

    private func provider(body: String, maximumOutputBytes: Int = 1_000_000) async throws -> OpenAIResponsesTextProvider {
        let credentials = MemoryCredentials()
        let client = OpenAIAccountClient(credentials: credentials, transport: StubTransport(exchange: exchange(status: 200, chunks: [])))
        try await credentials.setCredential(sessionJSON(), for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        return OpenAIResponsesTextProvider(
            accountClient: client,
            transport: StubTransport(exchange: exchange(status: 200, chunks: [Data(body.utf8)])),
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private func accountClient() async throws -> OpenAIAccountClient {
        let credentials = MemoryCredentials()
        try await credentials.setCredential(sessionJSON(), for: OpenAIAccountClient.credentialKey(for: "chatgpt-account"))
        return OpenAIAccountClient(credentials: credentials, transport: StubTransport(exchange: exchange(status: 200, chunks: [])))
    }

    private func outputItemDone(
        outputIndex: Int,
        itemID: String,
        phaseJSON: String? = #""final_answer""#,
        text: String
    ) -> String {
        let phaseField = phaseJSON.map { #""phase":\#($0),"# } ?? ""
        return #"data: {"type":"response.output_item.done","output_index":\#(outputIndex),"item":{"id":"\#(itemID)","type":"message","role":"assistant","status":"completed",\#(phaseField)"content":[{"type":"output_text","text":"\#(text)"}]}}"# + "\n\n"
    }
}

private func request(
    reportResponseMetadata: (@MainActor @Sendable (ResponseMetadata) -> Void)? = nil,
    model: String = "gpt-6.1-sol",
    reasoningEffort: String? = nil,
    reasoningEffortCapabilities: ReasoningEffortCapabilities? = nil
) -> TransformationRequest {
    TransformationRequest(
        text: "selected text",
        instruction: "rewrite",
        provider: ProviderConfiguration(
            id: "chatgpt-account",
            name: "ChatGPT",
            kind: .openAIChatGPT,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: model,
            reasoningEffort: reasoningEffort,
            reasoningEffortCapabilities: reasoningEffortCapabilities
        ),
        reportResponseMetadata: reportResponseMetadata
    )
}

private func sessionJSON() -> String {
    #"{"clientID":"oaiapp_fixture","hostID":"urn:uuid:00000000-0000-0000-0000-000000000001","subject":"subject-fixture","email":"user@example.invalid","idToken":"synthetic-id-token","accessToken":"fixture-access","refreshToken":"fixture-refresh","tokenType":"Bearer","expiresAt":4102444800,"scopes":["openid","profile","email","offline_access","resource.invoke","chatgpt.tokens.use.direct"]}"#
}

private actor MemoryCredentials: CredentialStore {
    private var values: [String: String] = [:]
    func credential(for providerID: String) async throws -> String? { values[providerID] }
    func setCredential(_ value: String?, for providerID: String) async throws { values[providerID] = value }
}

@MainActor
private final class ResponseMetadataReports {
    var values: [ResponseMetadata] = []
}

private actor StubTransport: StreamingHTTPTransport {
    private let response: HTTPExchange
    private var lastRequest: URLRequest?
    init(exchange: HTTPExchange) { response = exchange }
    func captured() -> URLRequest? { lastRequest }
    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        lastRequest = request
        return response
    }
}

private func exchange(status: Int, chunks: [Data]) -> HTTPExchange {
    HTTPExchange(
        statusCode: status,
        headers: ["content-type": "text/event-stream"],
        body: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    )
}

private func collect(_ provider: OpenAIResponsesTextProvider, request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    var output = ""
    for try await piece in stream { output += piece }
    return output
}
