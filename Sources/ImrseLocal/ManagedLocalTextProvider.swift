import Foundation
import ImrseCore
#if os(macOS) && arch(arm64)
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

enum ManagedLocalGenerationTermination: Sendable, Equatable {
    case stop
    case length
    case cancelled
    case incomplete
}

struct ManagedLocalGenerationResult: Sendable {
    let text: String
    let generationTokenCount: Int
    let termination: ManagedLocalGenerationTermination
}

enum ManagedLocalGenerationLimits {
    static let maximumPreparedPromptTokens = 8_192
    static let maximumGeneratedTokens = 2_048

    static func validatePreparedPromptTokenCount(_ count: Int) throws {
        guard count <= maximumPreparedPromptTokens else { throw ImrseError.selectionTooLarge }
    }
}

typealias ManagedLocalTextGeneration = @Sendable (
    URL, String, String, [String: any Sendable]
) async throws -> ManagedLocalGenerationResult

public struct ManagedLocalTextProvider: TextProvider, Sendable {
    private static let maximumTextBytes = 16 * 1_024
    private static let maximumInstructionBytes = 8 * 1_024
    fileprivate static let maximumOutputBytes = 256 * 1_024
    private let store: ManagedLocalModelStore
    private let generate: ManagedLocalTextGeneration

    public init(store: ManagedLocalModelStore) {
        self.store = store
        generate = { modelDirectory, instructions, prompt, context in
            try await ManagedLocalMLX.generate(
                modelDirectory: modelDirectory,
                instructions: instructions,
                prompt: prompt,
                additionalContext: context
            )
        }
    }

    init(store: ManagedLocalModelStore, generate: @escaping ManagedLocalTextGeneration) {
        self.store = store
        self.generate = generate
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, Error> {
        guard request.provider.kind == .managedLocal else { throw ImrseError.invalidConfiguration }
        guard ManagedLocalModelCatalog.model(id: request.provider.model) != nil else { throw ImrseError.missingModel }
        guard request.text.utf8.count <= Self.maximumTextBytes else { throw ImrseError.selectionTooLarge }
        guard request.instruction.utf8.count <= Self.maximumInstructionBytes else { throw ImrseError.instructionTooLarge }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let generation = try await generateCompletion(for: request)
                    try Task.checkCancellation()
                    switch generation.termination {
                    case .stop:
                        guard generation.generationTokenCount >= 0,
                              generation.generationTokenCount < ManagedLocalGenerationLimits.maximumGeneratedTokens
                        else { throw ImrseError.malformedResponse }
                    case .length, .incomplete:
                        throw ImrseError.malformedResponse
                    case .cancelled:
                        throw ImrseError.cancelled
                    }
                    let output = generation.text
                    guard output.utf8.count <= Self.maximumOutputBytes else { throw ImrseError.outputTooLarge }
                    guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImrseError.emptyOutput }
                    guard !Self.containsQwenReasoning(output) else { throw ImrseError.malformedResponse }
                    continuation.yield(output)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ImrseError.cancelled)
                } catch let error as ImrseError {
                    continuation.finish(throwing: error)
                } catch let error as ManagedLocalModelStoreError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: ImrseError.localModelUnavailable)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generateCompletion(for request: TransformationRequest) async throws -> ManagedLocalGenerationResult {
        let instructions = """
        Transform the selected text according to the user's instruction. Return only the transformed text, without commentary, explanation, analysis, reasoning, or tool calls.

        \(request.instruction)
        """
        let context: [String: any Sendable] = ["enable_thinking": false]
        return try await store.withInstalledModel(modelID: request.provider.model) { modelDirectory in
            try await generate(modelDirectory, instructions, request.text, context)
        }
    }

    private static func containsQwenReasoning(_ output: String) -> Bool {
        output.range(of: "<think>", options: .caseInsensitive) != nil
            || output.range(of: "</think>", options: .caseInsensitive) != nil
    }

    private static func map(_ error: ManagedLocalModelStoreError) -> ImrseError {
        switch error {
        case .missingModel, .unknownModel:
            .missingModel
        case .busy, .alreadyInstalled, .invalidManifest, .invalidInstalledModel, .integrityMismatch, .unsafeRedirect, .downloadFailed:
            .localModelUnavailable
        }
    }
}

private enum ManagedLocalMLX {
    static func generate(
        modelDirectory: URL,
        instructions: String,
        prompt: String,
        additionalContext: [String: any Sendable]
    ) async throws -> ManagedLocalGenerationResult {
        #if os(macOS) && arch(arm64)
        let model = try await loadModelContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        let input = try await model.prepare(
            input: UserInput(
                chat: [.system(instructions), .user(prompt)],
                additionalContext: additionalContext
            )
        )
        try ManagedLocalGenerationLimits.validatePreparedPromptTokenCount(input.text.tokens.size)
        try Task.checkCancellation()
        let stream = try await model.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: ManagedLocalGenerationLimits.maximumGeneratedTokens,
                temperature: 0
            )
        )
        var output = ""
        var outputBytes = 0
        var completionInfo: GenerateCompletionInfo?
        for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .chunk(let chunk):
                outputBytes += chunk.utf8.count
                guard outputBytes <= ManagedLocalTextProvider.maximumOutputBytes else {
                    throw ImrseError.outputTooLarge
                }
                output += chunk
            case .info(let info):
                guard completionInfo == nil else { throw ImrseError.malformedResponse }
                completionInfo = info
            case .toolCall:
                throw ImrseError.malformedResponse
            }
        }
        try Task.checkCancellation()
        guard let completionInfo else {
            return ManagedLocalGenerationResult(text: output, generationTokenCount: 0, termination: .incomplete)
        }
        let termination: ManagedLocalGenerationTermination
        switch completionInfo.stopReason {
        case .stop:
            termination = .stop
        case .length:
            termination = .length
        case .cancelled:
            termination = .cancelled
        }
        return ManagedLocalGenerationResult(
            text: output,
            generationTokenCount: completionInfo.generationTokenCount,
            termination: termination
        )
        #else
        throw ImrseError.localModelUnavailable
        #endif
    }
}
