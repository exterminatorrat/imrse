import Foundation
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAICompatibleProvider: TextProvider, Sendable {
    private static let maximumRequestBytes = 1_048_576
    private static let maximumAllowedOutputBytes = 8 * 1_024 * 1_024
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
                    if request.provider.requiresCredential {
                        guard let credential = try await credentials.credential(for: request.provider.id),
                              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { throw ImrseError.missingCredentials }
                        guard !credential.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                            throw ImrseError.authentication
                        }
                        let normalizedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedCredential.isEmpty, normalizedCredential.utf8.count <= 4_096,
                              normalizedCredential.utf8.allSatisfy({ (33...126).contains($0) })
                        else { throw ImrseError.authentication }
                        urlRequest.setValue("Bearer \(normalizedCredential)", forHTTPHeaderField: "Authorization")
                    }

                    let response = try await transport.execute(urlRequest, localOnly: request.localOnly)
                    exchange = response
                    guard (200..<300).contains(response.statusCode) else {
                        let error = Self.error(forStatus: response.statusCode)
                        response.cancel()
                        throw error
                    }

                    try await consume(response, request: request, continuation: continuation)
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
        guard [.openAI, .openRouter, .compatible].contains(request.provider.kind) else {
            throw ImrseError.invalidConfiguration
        }
        guard !request.provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImrseError.missingModel
        }
        try ProviderValidation.validate(request.provider)
        guard request.text.utf8.count <= Self.maximumRequestBytes else { throw ImrseError.selectionTooLarge }
        guard request.instruction.utf8.count <= 65_536 else { throw ImrseError.instructionTooLarge }
        if request.localOnly, !ProviderValidation.isLoopback(request.provider.endpoint) {
            throw ImrseError.localModelUnavailable
        }
    }

    private func makeRequest(_ request: TransformationRequest) throws -> URLRequest {
        guard let url = Self.completionsURL(for: request.provider.endpoint) else { throw ImrseError.invalidConfiguration }
        let body = ChatCompletionRequest(
            model: request.provider.model,
            messages: [
                ChatMessage(role: "system", content: request.instruction),
                ChatMessage(role: "user", content: request.text)
            ],
            stream: true
        )
        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw ImrseError.invalidConfiguration
        }
        guard data.count <= Self.maximumRequestBytes + 65_536 else { throw ImrseError.selectionTooLarge }

        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return urlRequest
    }

    private func consume(
        _ exchange: HTTPExchange,
        request: TransformationRequest,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let maximumResponseBytes = maximumOutputBytes + 2_097_152
        let maximumEventBytes = min(maximumOutputBytes + 65_536, 10 * 1_024 * 1_024)
        var parser = SSEParser(maximumEventBytes: maximumEventBytes)
        var responseBytes = 0
        var outputBytes = 0
        var completed = false
        var responseMetadata: ResponseMetadata?

        for try await chunk in exchange.body {
            try Task.checkCancellation()
            responseBytes += chunk.count
            guard responseBytes <= maximumResponseBytes else { throw ImrseError.outputTooLarge }
            let events = try parser.append(chunk)
            for event in events {
                if try consume(
                    event,
                    providerKind: request.provider.kind,
                    outputBytes: &outputBytes,
                    completed: &completed,
                    responseMetadata: &responseMetadata,
                    continuation: continuation
                ) {
                    break
                }
            }
            if completed { break }
        }

        if !completed {
            for event in try parser.finish() {
                if try consume(
                    event,
                    providerKind: request.provider.kind,
                    outputBytes: &outputBytes,
                    completed: &completed,
                    responseMetadata: &responseMetadata,
                    continuation: continuation
                ) {
                    break
                }
            }
        }
        guard completed else { throw ImrseError.interruptedStream }
        guard outputBytes > 0 else { throw ImrseError.emptyOutput }
        try Task.checkCancellation()
        if let responseMetadata { await request.reportResponseMetadata?(responseMetadata) }
    }

    private func consume(
        _ event: String,
        providerKind: ProviderKind,
        outputBytes: inout Int,
        completed: inout Bool,
        responseMetadata: inout ResponseMetadata?,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) throws -> Bool {
        if event == "[DONE]" {
            completed = true
            return true
        }
        guard let data = event.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ImrseError.malformedResponse }
        if let error = object["error"], !(error is NSNull) { throw ImrseError.server }
        guard let choices = object["choices"] as? [[String: Any]] else { throw ImrseError.malformedResponse }
        guard choices.count <= 1 else { throw ImrseError.malformedResponse }

        let usage = object["usage"] as? [String: Any]
        if let metadata = ResponseMetadataParser.parse(
            model: object["model"],
            inputTokens: usage?["prompt_tokens"],
            outputTokens: usage?["completion_tokens"],
            totalTokens: usage?["total_tokens"],
            costUSD: providerKind == .openRouter ? usage?["cost"] : nil
        ) {
            let previous = responseMetadata
            responseMetadata = ResponseMetadata(
                detectedModel: metadata.detectedModel ?? previous?.detectedModel,
                inputTokens: metadata.inputTokens ?? previous?.inputTokens,
                outputTokens: metadata.outputTokens ?? previous?.outputTokens,
                totalTokens: metadata.totalTokens ?? previous?.totalTokens,
                costUSD: metadata.costUSD ?? previous?.costUSD
            )
        }

        for choice in choices {
            if let delta = choice["delta"] as? [String: Any], let content = delta["content"] {
                if let text = content as? String {
                    outputBytes += text.utf8.count
                    guard outputBytes <= maximumOutputBytes else { throw ImrseError.outputTooLarge }
                    if !text.isEmpty {
                        if case .terminated = continuation.yield(text) { throw CancellationError() }
                    }
                } else if !(content is NSNull) {
                    throw ImrseError.malformedResponse
                }
            } else if choice["delta"] != nil && !(choice["delta"] is NSNull) {
                throw ImrseError.malformedResponse
            }

            if let finishReason = choice["finish_reason"], !(finishReason is NSNull) {
                guard let reason = finishReason as? String else { throw ImrseError.malformedResponse }
                guard reason == "stop" else { throw ImrseError.interruptedStream }
                completed = true
            }
        }
        return completed
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

    private static func completionsURL(for endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            components.path = path
        } else if path == "/" || path.isEmpty {
            components.path = "/v1/chat/completions"
        } else if path.hasSuffix("/v1") {
            components.path = path + "/chat/completions"
        } else {
            components.path = path + "/chat/completions"
        }
        return components.url
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}
