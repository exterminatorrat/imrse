import Foundation
import ImrseCore

public struct ProviderRoute: Equatable, Sendable {
    public let primary: ProviderConfiguration
    public let fallback: ProviderConfiguration?
    public let localOnly: Bool

    public init(primary: ProviderConfiguration, fallback: ProviderConfiguration? = nil, localOnly: Bool = false) {
        self.primary = primary
        self.fallback = fallback
        self.localOnly = localOnly
    }

    public func makeRequest(
        text: String,
        instruction: String,
        reportProvider: (@MainActor @Sendable (ProviderConfiguration) -> Void)? = nil
    ) -> TransformationRequest {
        TransformationRequest(
            text: text,
            instruction: instruction,
            provider: primary,
            localOnly: localOnly,
            fallbackProvider: fallback,
            reportProvider: reportProvider
        )
    }
}

public struct ProviderRouter: Sendable {
    private let configuration: AppConfiguration

    public init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    public func resolve(preset: Preset? = nil, localOnly: Bool = false) throws -> ProviderRoute {
        try ProviderValidation.validate(configuration)
        if let preset { try ProviderValidation.validate(preset) }

        let isLocalOnly = localOnly || preset?.localOnly == true
        let selectedID = preset?.providerID ?? configuration.selectedProviderID
        guard let selectedID else {
            throw isLocalOnly ? ImrseError.localModelUnavailable : ImrseError.providerUnavailable
        }
        guard var primary = configuration.providers.first(where: { $0.id == selectedID }) else {
            throw preset?.providerID == nil ? (isLocalOnly ? ImrseError.localModelUnavailable : ImrseError.providerUnavailable) : ImrseError.invalidPreset
        }

        if let model = preset?.model { primary.model = model }

        var fallback: ProviderConfiguration?
        if let fallbackID = preset?.fallbackProviderID {
            guard fallbackID != primary.id,
                  let configuredFallback = configuration.providers.first(where: { $0.id == fallbackID })
            else { throw ImrseError.invalidPreset }
            fallback = isLocalOnly && !ProviderValidation.isLocal(configuredFallback)
                ? nil
                : configuredFallback
        }

        if isLocalOnly {
            guard ProviderValidation.isLocal(primary) else { throw ImrseError.localModelUnavailable }
        }
        if ProviderValidation.isAccount(primary), let candidate = fallback, !ProviderValidation.isLocal(candidate) {
            fallback = nil
        }

        return ProviderRoute(primary: primary, fallback: fallback, localOnly: isLocalOnly)
    }

    public static func isLoopback(_ endpoint: URL) -> Bool {
        ProviderValidation.isLoopback(endpoint)
    }
}
