import Foundation
import ImrseCore

public struct ProviderDispatchProvider: TextProvider, Sendable {
    private let compatible: any TextProvider
    private let account: (any TextProvider)?
    private let local: (any TextProvider)?

    public init(compatible: any TextProvider, account: (any TextProvider)? = nil, local: (any TextProvider)? = nil) {
        self.compatible = compatible
        self.account = account
        self.local = local
    }

    public func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        try ProviderValidation.validate(request.provider)
        switch request.provider.kind {
        case .managedLocal:
            guard let local else { throw ImrseError.localModelUnavailable }
            return try await local.stream(request)
        case .openAIChatGPT:
            guard !request.localOnly, let account else { throw ImrseError.providerUnavailable }
            return try await account.stream(request)
        case .openAI, .openRouter, .compatible:
            return try await compatible.stream(request)
        }
    }
}
