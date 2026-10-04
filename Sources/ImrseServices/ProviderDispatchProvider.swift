import Foundation
import ImrseCore

public struct ProviderDispatchProvider: TextProvider, Sendable {
    private let compatible: any TextProvider
    private let account: (any TextProvider)?
    private let local: (any TextProvider)?
    private let anthropic: (any TextProvider)?
    private let officialAccount: (any TextProvider)?
    private let copilot: (any TextProvider)?

    public init(
        compatible: any TextProvider,
        account: (any TextProvider)? = nil,
        local: (any TextProvider)? = nil,
        anthropic: (any TextProvider)? = nil,
        officialAccount: (any TextProvider)? = nil,
        copilot: (any TextProvider)? = nil
    ) {
        self.compatible = compatible
        self.account = account
        self.local = local
        self.anthropic = anthropic
        self.officialAccount = officialAccount
        self.copilot = copilot
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        try ProviderValidation.validate(request.provider)
        if request.localOnly, !ProviderValidation.isLocal(request.provider) {
            throw ImrseError.localModelUnavailable
        }
        switch request.provider.kind {
        case .managedLocal:
            guard let local else { throw ImrseError.localModelUnavailable }
            return try await local.stream(request)
        case .openAIChatGPT:
            guard !request.localOnly, let account else { throw ImrseError.providerUnavailable }
            return try await account.stream(request)
        case .openAI, .openRouter, .compatible:
            return try await compatible.stream(request)
        case .anthropic:
            guard let anthropic else { throw ImrseError.providerUnavailable }
            return try await anthropic.stream(request)
        case .openRouterAccount, .huggingFaceAccount:
            guard !request.localOnly, let officialAccount else { throw ImrseError.providerUnavailable }
            return try await officialAccount.stream(request)
        case .githubCopilot:
            guard !request.localOnly, let copilot else { throw ImrseError.providerUnavailable }
            return try await copilot.stream(request)
        }
    }
}
