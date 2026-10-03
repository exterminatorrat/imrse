import Foundation
import CoreFoundation
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct StreamedOutputBytes {
    private var itemsByIndex: [Int: String] = [:]
    private var indicesByItem: [String: Int] = [:]
    private var bytesByIndex: [Int: Int] = [:]

    mutating func register(itemID: String, outputIndex: Int) throws {
        guard !itemID.isEmpty, outputIndex >= 0 else { throw ImrseError.malformedResponse }
        if let itemAtIndex = itemsByIndex[outputIndex], itemAtIndex != itemID {
            throw ImrseError.malformedResponse
        }
        if let indexForItem = indicesByItem[itemID], indexForItem != outputIndex {
            throw ImrseError.malformedResponse
        }
        itemsByIndex[outputIndex] = itemID
        indicesByItem[itemID] = outputIndex
    }

    mutating func append(_ delta: String, itemID: String, outputIndex: Int, maximumBytes: Int) throws {
        try register(itemID: itemID, outputIndex: outputIndex)
        let currentBytes = bytesByIndex[outputIndex, default: 0]
        let deltaBytes = delta.utf8.count
        guard deltaBytes <= maximumBytes - currentBytes else { throw ImrseError.outputTooLarge }
        bytesByIndex[outputIndex] = currentBytes + deltaBytes
    }
}

private struct CompletedOutputItem: Equatable {
    let itemID: String
    let text: String
}

private enum OutputItemPhase: Equatable {
    case finalAnswer
    case analysis
    case commentary
}

private struct OutputItemDoneClassification: Equatable {
    let type: String?
    let phase: OutputItemPhase?
}

public struct OpenAIResponsesTextProvider: TextProvider, Sendable {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let baseEndpoint = URL(string: "https://api.openai.com/v1")!
    private static let maximumInputBytes = 1_048_576
    private static let maximumInstructionBytes = 8_192
    private static let maximumStreamBytes = 4_194_304
    private static let maximumErrorBodyBytes = 65_536
    private let accountClient: OpenAIAccountClient
    private let transport: any StreamingHTTPTransport
    private let maximumOutputBytes: Int

    public init(
        accountClient: OpenAIAccountClient,
        transport: any StreamingHTTPTransport = URLSessionHTTPTransport(),
        maximumOutputBytes: Int = 1_048_576
    ) {
        self.accountClient = accountClient
        self.transport = transport
        self.maximumOutputBytes = min(max(maximumOutputBytes, 1), Self.maximumStreamBytes)
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        guard request.provider.kind == .openAIChatGPT else { throw ImrseError.providerUnavailable }
        guard !request.localOnly else { throw ImrseError.localModelUnavailable }
        guard request.provider.endpoint == Self.baseEndpoint,
              isValidModel(request.provider.model),
              request.text.utf8.count <= Self.maximumInputBytes,
              request.instruction.utf8.count <= Self.maximumInstructionBytes
        else { throw ImrseError.invalidConfiguration }

        let accessToken: String
        do {
            accessToken = try await accountClient.freshAccessToken(for: request.provider.id)
        } catch let error as OpenAIAccountClientError {
            throw mapAccountError(error)
        }

        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: 180)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(ResponsesRequest(
            model: request.provider.model,
            instructions: request.instruction,
            input: [ResponsesInput(role: "user", content: request.text)],
            store: false,
            stream: true,
            reasoning: request.provider.activeReasoningEffort.flatMap {
                $0.format == .responsesObject ? ResponsesReasoning(effort: $0.effort) : nil
            }
        ))

        let exchange: HTTPExchange
        do {
            exchange = try await transport.execute(urlRequest, localOnly: false)
        } catch is CancellationError {
            throw ImrseError.cancelled
        } catch {
            throw ImrseError.network
        }

        let maximumOutputBytes = self.maximumOutputBytes
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.consume(
                        exchange,
                        maximumOutputBytes: maximumOutputBytes,
                        continuation: continuation,
                        reportResponseMetadata: request.reportResponseMetadata
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    private static func consume(
        _ exchange: HTTPExchange,
        maximumOutputBytes: Int,
        continuation: AsyncThrowingStream<String, any Error>.Continuation,
        reportResponseMetadata: (@MainActor @Sendable (ResponseMetadata) -> Void)?
    ) async throws {
        defer { exchange.cancel() }
        guard (200..<300).contains(exchange.statusCode) else {
            let failure = await readHTTPFailure(from: exchange)
            try Task.checkCancellation()
            throw mapHTTPStatus(exchange.statusCode, code: failure)
        }

        var decoder = ServerSentEventDecoder()
        var receivedBytes = 0
        var streamedOutputBytes = StreamedOutputBytes()
        var completedOutputItems: [Int: CompletedOutputItem] = [:]
        var outputItemDoneClassifications: [Int: OutputItemDoneClassification] = [:]
        var completed = false
        var finalOutput: String?
        var responseMetadata: ResponseMetadata?

        stream: for try await chunk in exchange.body {
            try Task.checkCancellation()
            guard chunk.count <= maximumStreamBytes - receivedBytes else { throw ImrseError.outputTooLarge }
            receivedBytes += chunk.count
            for frame in try decoder.append(chunk) {
                let result = try consumeFrame(
                    frame,
                    streamedOutputBytes: &streamedOutputBytes,
                    completedOutputItems: &completedOutputItems,
                    outputItemDoneClassifications: &outputItemDoneClassifications,
                    maximumOutputBytes: maximumOutputBytes,
                    responseMetadata: &responseMetadata
                )
                if result.completed {
                    completed = true
                    finalOutput = result.finalOutput
                    break stream
                }
            }
        }
        if !completed {
            for frame in try decoder.finish() {
                let result = try consumeFrame(
                    frame,
                    streamedOutputBytes: &streamedOutputBytes,
                    completedOutputItems: &completedOutputItems,
                    outputItemDoneClassifications: &outputItemDoneClassifications,
                    maximumOutputBytes: maximumOutputBytes,
                    responseMetadata: &responseMetadata
                )
                if result.completed {
                    completed = true
                    finalOutput = result.finalOutput
                    break
                }
            }
        }
        try Task.checkCancellation()
        guard completed, let finalOutput else { throw ImrseError.interruptedStream }
        guard finalOutput.utf8.count <= maximumOutputBytes else { throw ImrseError.outputTooLarge }
        guard !finalOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImrseError.emptyOutput }
        guard case .enqueued = continuation.yield(finalOutput) else { throw ImrseError.cancelled }
        try Task.checkCancellation()
        if let responseMetadata { await reportResponseMetadata?(responseMetadata) }
    }

    private static func consumeFrame(
        _ frame: String,
        streamedOutputBytes: inout StreamedOutputBytes,
        completedOutputItems: inout [Int: CompletedOutputItem],
        outputItemDoneClassifications: inout [Int: OutputItemDoneClassification],
        maximumOutputBytes: Int,
        responseMetadata: inout ResponseMetadata?
    ) throws -> (finalOutput: String?, completed: Bool) {
        guard frame != "[DONE]",
              let data = frame.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any],
              let type = event["type"] as? String
        else {
            if frame == "[DONE]" { return (nil, false) }
            throw ImrseError.malformedResponse
        }

        switch type {
        case "response.output_text.delta":
            _ = try isFinalPhase(event)
            guard let delta = event["delta"] as? String,
                  let itemID = event["item_id"] as? String
            else { throw ImrseError.malformedResponse }
            let outputIndex = try validatedOutputIndex(event["output_index"])
            try streamedOutputBytes.append(
                delta,
                itemID: itemID,
                outputIndex: outputIndex,
                maximumBytes: maximumOutputBytes
            )
            return (nil, false)
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any],
                  let itemID = item["id"] as? String
            else { throw ImrseError.malformedResponse }
            let outputIndex = try validatedOutputIndex(event["output_index"])
            try streamedOutputBytes.register(itemID: itemID, outputIndex: outputIndex)
            let itemType = item["type"] as? String
            let phase: OutputItemPhase?
            if itemType == "message" {
                phase = try outputItemPhase(item)
            } else {
                phase = nil
            }
            let classification = OutputItemDoneClassification(type: itemType, phase: phase)
            if let existingClassification = outputItemDoneClassifications[outputIndex] {
                guard existingClassification == classification else { throw ImrseError.malformedResponse }
            } else {
                outputItemDoneClassifications[outputIndex] = classification
            }
            guard itemType == "message", phase == .finalAnswer else { return (nil, false) }
            guard item["role"] as? String == "assistant",
                  let itemStatus = item["status"] as? String
            else { throw ImrseError.malformedResponse }
            guard itemStatus == "completed" else { throw ImrseError.interruptedStream }
            guard let content = item["content"] as? [[String: Any]] else { throw ImrseError.malformedResponse }
            let completedItem = CompletedOutputItem(itemID: itemID, text: try outputText(from: content))
            if let existingItem = completedOutputItems[outputIndex] {
                guard existingItem == completedItem else { throw ImrseError.malformedResponse }
            } else {
                completedOutputItems[outputIndex] = completedItem
            }
            return (nil, false)
        case "response.completed":
            let output = try completedOutput(
                from: event,
                completedOutputItems: completedOutputItems,
                maximumOutputBytes: maximumOutputBytes
            )
            let response = event["response"] as? [String: Any]
            let usage = response?["usage"] as? [String: Any]
            responseMetadata = ResponseMetadataParser.parse(
                model: response?["model"],
                inputTokens: usage?["input_tokens"],
                outputTokens: usage?["output_tokens"],
                totalTokens: usage?["total_tokens"],
                costUSD: nil
            )
            return (output, true)
        case "response.failed":
            throw mapResponseFailure(event)
        case "response.incomplete":
            throw ImrseError.interruptedStream
        default:
            return (nil, false)
        }
    }

    private static func validatedOutputIndex(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let index = value as? Int,
              index >= 0
        else { throw ImrseError.malformedResponse }
        return index
    }

    private static func completedOutput(
        from event: [String: Any],
        completedOutputItems: [Int: CompletedOutputItem],
        maximumOutputBytes: Int
    ) throws -> String {
        guard let response = event["response"] as? [String: Any],
              let status = response["status"] as? String,
              let items = response["output"] as? [[String: Any]]
        else { throw ImrseError.malformedResponse }
        guard status == "completed" else { throw ImrseError.interruptedStream }

        if items.isEmpty {
            var output = ""
            var outputBytes = 0
            for (_, item) in completedOutputItems.sorted(by: { $0.key < $1.key }) {
                let textBytes = item.text.utf8.count
                guard textBytes <= maximumOutputBytes - outputBytes else { throw ImrseError.outputTooLarge }
                outputBytes += textBytes
                output.append(item.text)
            }
            return output
        }

        var output = ""
        var outputBytes = 0
        for item in items where item["type"] as? String == "message" {
            guard try isFinalPhase(item) else { continue }
            guard item["role"] as? String == "assistant",
                  let itemStatus = item["status"] as? String
            else { throw ImrseError.malformedResponse }
            guard itemStatus == "completed" else { throw ImrseError.interruptedStream }
            guard let content = item["content"] as? [[String: Any]] else { throw ImrseError.malformedResponse }
            let text = try outputText(from: content)
            let textBytes = text.utf8.count
            guard textBytes <= maximumOutputBytes - outputBytes else { throw ImrseError.outputTooLarge }
            outputBytes += textBytes
            output.append(text)
        }
        return output
    }

    private static func outputText(from content: [[String: Any]]) throws -> String {
        var output = ""
        for part in content where part["type"] as? String == "output_text" {
            guard let text = part["text"] as? String else { throw ImrseError.malformedResponse }
            output.append(text)
        }
        return output
    }

    private static func isFinalPhase(_ object: [String: Any]) throws -> Bool {
        try outputItemPhase(object) == .finalAnswer
    }

    private static func outputItemPhase(_ object: [String: Any]) throws -> OutputItemPhase {
        guard let phase = object["phase"], !(phase is NSNull) else { return .finalAnswer }
        guard let phase = phase as? String else { throw ImrseError.malformedResponse }
        switch phase {
        case "final_answer": return .finalAnswer
        case "analysis": return .analysis
        case "commentary": return .commentary
        default: throw ImrseError.malformedResponse
        }
    }

    private static func mapHTTPStatus(_ status: Int, code: String?) -> ImrseError {
        if let code, let error = mapSubscriptionCode(code) { return error }
        return switch status {
        case 401, 403: .authentication
        case 408: .timeout
        case 429: .rateLimited
        case 500...599: .server
        default: .server
        }
    }

    private static func mapResponseFailure(_ event: [String: Any]) -> ImrseError {
        let nested = event["response"] as? [String: Any]
        let error = (event["error"] as? [String: Any]) ?? (nested?["error"] as? [String: Any])
        if let code = error?["code"] as? String,
           code.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil,
           let mapped = mapSubscriptionCode(code)
        {
            return mapped
        }
        return .server
    }

    private static func readHTTPFailure(from exchange: HTTPExchange) async -> String? {
        var data = Data()
        do {
            for try await chunk in exchange.body {
                try Task.checkCancellation()
                guard chunk.count <= maximumErrorBodyBytes - data.count else { return nil }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any],
              let error = response["error"] as? [String: Any]
        else { return nil }
        let code = error["code"] as? String
        return code.flatMap { $0.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil ? $0 : nil }
    }

    private static func mapSubscriptionCode(_ code: String) -> ImrseError? {
        switch code {
        case "subscription_sharing_user_not_eligible",
             "subscription_sharing_usage_limit_exceeded",
             "subscription_sharing_invalid_user",
             "chatpass_v2_scope_not_authorized",
             "chatpass_v2_invalid_authorization_context": .authentication
        case "subscription_sharing_unsupported_capability",
             "subscription_sharing_route_not_supported": .invalidConfiguration
        default: nil
        }
    }

    private func mapAccountError(_ error: OpenAIAccountClientError) -> ImrseError {
        switch error {
        case .cancelled: .cancelled
        case .networkFailure: .network
        case .requestFailed(401), .requestFailed(403): .authentication
        case .requestFailed(408): .timeout
        case .requestFailed(429): .rateLimited
        case .requestFailed(500...599): .server
        case .invalidGrant, .reauthorizationRequired: .authentication
        case .invalidClientConfiguration: .invalidConfiguration
        case .responseTooLarge: .outputTooLarge
        case .malformedResponse: .malformedResponse
        case .invalidConfiguration, .invalidCallback: .invalidConfiguration
        default: .authentication
        }
    }

    private func isValidModel(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 256
            && model.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [ResponsesInput]
    let store: Bool
    let stream: Bool
    let reasoning: ResponsesReasoning?
}

private struct ResponsesReasoning: Encodable {
    let effort: String
}

private struct ResponsesInput: Encodable {
    let role: String
    let content: String
}

private struct ServerSentEventDecoder {
    private var remaining = Data()
    private var eventData = Data()

    mutating func append(_ chunk: Data) throws -> [String] {
        remaining.append(chunk)
        var frames: [String] = []
        while let newline = remaining.firstIndex(of: 0x0a) {
            let lineData = Data(remaining[..<newline])
            remaining.removeSubrange(...newline)
            try processLine(lineData, into: &frames)
        }
        guard remaining.count <= 1_048_576 else { throw ImrseError.outputTooLarge }
        return frames
    }

    mutating func finish() throws -> [String] {
        var frames: [String] = []
        if !remaining.isEmpty {
            try processLine(remaining, into: &frames)
            remaining.removeAll(keepingCapacity: false)
        }
        if !eventData.isEmpty {
            try appendFrame(into: &frames)
        }
        return frames
    }

    private mutating func processLine(_ bytes: Data, into frames: inout [String]) throws {
        var line = Data(bytes)
        if line.last == 0x0d { line.removeLast() }
        guard let value = String(data: line, encoding: .utf8) else { throw ImrseError.malformedResponse }
        if value.isEmpty {
            try appendFrame(into: &frames)
            return
        }
        guard !value.hasPrefix(":") else { return }
        guard value.hasPrefix("data:") else { return }
        var dataValue = String(value.dropFirst(5))
        if dataValue.first == " " { dataValue.removeFirst() }
        if !eventData.isEmpty { eventData.append(0x0a) }
        eventData.append(contentsOf: dataValue.utf8)
        guard eventData.count <= 1_048_576 else { throw ImrseError.outputTooLarge }
    }

    private mutating func appendFrame(into frames: inout [String]) throws {
        guard !eventData.isEmpty else { return }
        guard let frame = String(data: eventData, encoding: .utf8) else { throw ImrseError.malformedResponse }
        frames.append(frame)
        eventData.removeAll(keepingCapacity: true)
    }
}
