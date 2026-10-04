import Foundation
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AnthropicTextProvider: TextProvider, Sendable {
    private static let maximumRequestBytes = 1_048_576
    private static let maximumAllowedOutputBytes = 8 * 1_024 * 1_024
    private static let maximumTokens = 4_096
    private let credentials: any CredentialStore
    private let transport: any StreamingHTTPTransport
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(
        credentials: any CredentialStore,
        transport: any StreamingHTTPTransport = URLSessionHTTPTransport(),
        timeout: TimeInterval = 60,
        maximumOutputBytes: Int = 1_000_000
    ) {
        self.credentials = credentials
        self.transport = transport
        self.timeout = timeout.isFinite ? min(max(timeout, 1), 300) : 60
        self.maximumOutputBytes = min(max(maximumOutputBytes, 1), Self.maximumAllowedOutputBytes)
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        try validate(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var exchange: HTTPExchange?
                do {
                    var urlRequest = try makeRequest(request)
                    guard let credential = try await credentials.credential(for: request.provider.id),
                          !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { throw ImrseError.missingCredentials }
                    let normalizedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard normalizedCredential.utf8.count <= 4_096,
                          normalizedCredential.utf8.allSatisfy({ (33...126).contains($0) })
                    else { throw ImrseError.authentication }
                    urlRequest.setValue(normalizedCredential, forHTTPHeaderField: "x-api-key")

                    let response = try await transport.execute(urlRequest, localOnly: request.localOnly)
                    exchange = response
                    guard (200..<300).contains(response.statusCode) else {
                        let error = Self.error(forStatus: response.statusCode)
                        response.cancel()
                        throw error
                    }

                    try await consume(response, continuation: continuation)
                    response.cancel()
                    continuation.finish()
                } catch {
                    exchange?.cancel()
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validate(_ request: TransformationRequest) throws {
        guard request.provider.kind == .anthropic else { throw ImrseError.invalidConfiguration }
        try ProviderValidation.validate(request.provider)
        guard !request.provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImrseError.missingModel
        }
        guard request.text.utf8.count <= Self.maximumRequestBytes else { throw ImrseError.selectionTooLarge }
        guard request.instruction.utf8.count <= 65_536 else { throw ImrseError.instructionTooLarge }
        if request.localOnly, !ProviderValidation.isLocal(request.provider) {
            throw ImrseError.localModelUnavailable
        }
    }

    private func makeRequest(_ request: TransformationRequest) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ImrseError.invalidConfiguration
        }
        let body = MessagesRequest(
            model: request.provider.model,
            maxTokens: Self.maximumTokens,
            system: request.instruction,
            messages: [MessagesRequest.Message(role: "user", content: request.text)],
            stream: true
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw ImrseError.invalidConfiguration
        }
        guard data.count <= Self.maximumRequestBytes + 65_536 else { throw ImrseError.selectionTooLarge }

        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return urlRequest
    }

    private func consume(
        _ exchange: HTTPExchange,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let maximumResponseBytes = maximumOutputBytes + 2_097_152
        let maximumEventBytes = min(maximumOutputBytes + 65_536, 10 * 1_024 * 1_024)
        var parser = SSEParser(maximumEventBytes: maximumEventBytes)
        var state = MessageState()
        var responseBytes = 0

        for try await chunk in exchange.body {
            try Task.checkCancellation()
            guard chunk.count <= maximumResponseBytes - responseBytes else { throw ImrseError.outputTooLarge }
            responseBytes += chunk.count
            for event in try parser.append(chunk) {
                if try consume(event, state: &state, continuation: continuation) { break }
            }
            if state.completed { break }
        }

        if !state.completed {
            for event in try parser.finish() {
                if try consume(event, state: &state, continuation: continuation) { break }
            }
        }
        guard state.completed else { throw ImrseError.interruptedStream }
        guard state.outputBytes > 0 else { throw ImrseError.emptyOutput }
        try Task.checkCancellation()
    }

    private func consume(
        _ event: String,
        state: inout MessageState,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) throws -> Bool {
        guard let data = event.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { throw ImrseError.malformedResponse }

        switch type {
        case "ping":
            return false
        case "error":
            throw ImrseError.server
        case "message_start":
            guard !state.messageStarted,
                  let message = object["message"] as? [String: Any],
                  message["type"] as? String == "message",
                  message["role"] as? String == "assistant",
                  message["content"] is [Any]
            else { throw ImrseError.malformedResponse }
            state.messageStarted = true
        case "content_block_start":
            guard state.messageStarted,
                  !state.messageDeltaReceived,
                  let index = object["index"] as? Int,
                  state.blocks[index] == nil,
                  let block = object["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String
            else { throw ImrseError.malformedResponse }
            switch blockType {
            case "text": state.blocks[index] = .text
            case "thinking", "redacted_thinking": state.blocks[index] = .suppressed
            default: throw ImrseError.interruptedStream
            }
        case "content_block_delta":
            guard state.messageStarted,
                  !state.messageDeltaReceived,
                  let index = object["index"] as? Int,
                  let block = state.blocks[index],
                  let delta = object["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String
            else { throw ImrseError.malformedResponse }
            if block == .suppressed {
                guard ["thinking_delta", "signature_delta", "redacted_thinking_delta"].contains(deltaType) else {
                    throw ImrseError.interruptedStream
                }
            } else if deltaType == "text_delta", let text = delta["text"] as? String {
                state.outputBytes += text.utf8.count
                guard state.outputBytes <= maximumOutputBytes else { throw ImrseError.outputTooLarge }
                if !text.isEmpty, case .terminated = continuation.yield(text) { throw CancellationError() }
            } else if deltaType == "citations_delta" {
                break
            } else {
                throw ImrseError.interruptedStream
            }
        case "content_block_stop":
            guard state.messageStarted,
                  let index = object["index"] as? Int,
                  state.blocks.removeValue(forKey: index) != nil
            else { throw ImrseError.malformedResponse }
        case "message_delta":
            guard state.messageStarted,
                  state.blocks.isEmpty,
                  let delta = object["delta"] as? [String: Any]
            else { throw ImrseError.malformedResponse }
            if let stopReason = delta["stop_reason"] as? String {
                guard stopReason == "end_turn" || stopReason == "stop_sequence" else {
                    throw ImrseError.interruptedStream
                }
                state.successfulStopReason = true
            } else if let stopReason = delta["stop_reason"], !(stopReason is NSNull) {
                throw ImrseError.malformedResponse
            }
            state.messageDeltaReceived = true
        case "message_stop":
            guard state.messageStarted,
                  state.messageDeltaReceived,
                  state.successfulStopReason,
                  state.blocks.isEmpty,
                  !state.completed
            else {
                throw ImrseError.interruptedStream
            }
            state.completed = true
            return true
        default:
            throw ImrseError.malformedResponse
        }
        return false
    }

    private static func error(forStatus status: Int) -> ImrseError {
        if status == 401 || status == 403 { return .authentication }
        if status == 429 { return .rateLimited }
        if status == 408 || status == 504 { return .timeout }
        if (500..<600).contains(status) { return .server }
        return .invalidConfiguration
    }

    private static func map(_ error: any Error) -> ImrseError {
        if let error = error as? ImrseError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            if error.code == .timedOut { return .timeout }
        }
        return .network
    }
}

private struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream
        case maxTokens = "max_tokens"
    }
}

private struct MessageState {
    enum Block: Equatable { case text, suppressed }

    var messageStarted = false
    var messageDeltaReceived = false
    var successfulStopReason = false
    var completed = false
    var outputBytes = 0
    var blocks: [Int: Block] = [:]
}
