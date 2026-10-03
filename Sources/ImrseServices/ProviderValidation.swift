import Foundation
import ImrseCore

enum ProviderValidation {
    static func validate(_ configuration: AppConfiguration) throws {
        guard configuration.version == 1,
              configuration.providers.count <= 32,
              configuration.providers.allSatisfy(isValidProvider),
              Set(configuration.providers.map(\.id)).count == configuration.providers.count,
              configuration.selectedProviderID.map({ id in configuration.providers.contains { $0.id == id } }) ?? true,
              configuration.invocation.doubleControlInterval.isFinite,
              (0.05...1.0).contains(configuration.invocation.doubleControlInterval)
        else { throw ImrseError.invalidConfiguration }

        if let shortcut = configuration.invocation.shortcut {
            try validate(shortcut)
        }
    }

    static func validate(_ preset: Preset) throws {
        guard isValidIdentifier(preset.id),
              isValidName(preset.name),
              isValidInstruction(preset.instruction),
              preset.providerID.map(isValidIdentifier) ?? true,
              preset.model.map(isValidModel) ?? true,
              preset.fallbackProviderID.map(isValidIdentifier) ?? true,
              preset.context == .selection
        else { throw ImrseError.invalidPreset }

        if let shortcut = preset.shortcut {
            do { try validate(shortcut) }
            catch { throw ImrseError.shortcutConflict }
        }
    }

    static func validate(_ provider: ProviderConfiguration) throws {
        guard isValidProvider(provider) else { throw ImrseError.invalidConfiguration }
    }

    static func validateShortcuts(configuration: AppConfiguration, presets: [Preset]) throws {
        var shortcuts: [ShortcutBinding] = []
        if let shortcut = configuration.invocation.shortcut { shortcuts.append(shortcut) }
        shortcuts += presets.compactMap(\.shortcut)
        guard Set(shortcuts.map(ShortcutKey.init)).count == shortcuts.count else {
            throw ImrseError.shortcutConflict
        }
    }

    static func validate(_ shortcut: ShortcutBinding) throws {
        guard shortcut.keyCode <= 127,
              shortcut.command || shortcut.option || shortcut.control || shortcut.shift
        else { throw ImrseError.shortcutConflict }
    }

    static func isValidProvider(_ provider: ProviderConfiguration) -> Bool {
        guard isValidIdentifier(provider.id)
            && isValidName(provider.name)
            && isValidModel(provider.model)
            && (provider.reasoningEffort.map(isValidReasoningEffort) ?? true)
            && (provider.reasoningEffortCapabilities.map(isValidReasoningEffortCapabilities) ?? true)
        else { return false }
        switch provider.kind {
        case .managedLocal:
            return provider.endpoint == URL(string: "imrse-local://models") && !provider.requiresCredential
        case .openAIChatGPT:
            return provider.endpoint == URL(string: "https://api.openai.com/v1") && provider.requiresCredential
        case .openAI, .openRouter, .compatible:
            return isValidEndpoint(provider.endpoint)
        }
    }

    static func isLocal(_ provider: ProviderConfiguration) -> Bool {
        provider.kind == .managedLocal || isLoopback(provider.endpoint)
    }

    static func isValidEndpoint(_ endpoint: URL) -> Bool {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true
        else { return false }

        let isLoopback = isLoopbackHost(host)
        return (scheme == "https" || (scheme == "http" && isLoopback))
    }

    static func isLoopback(_ endpoint: URL) -> Bool {
        guard let host = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.host else { return false }
        return isLoopbackHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let host = host.lowercased()
        let value = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if value == "localhost" || value == "::1" || value == "0:0:0:0:0:0:0:1" { return true }
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]), first == 127,
              octets.allSatisfy({ part in
                  guard let number = Int(part) else { return false }
                  return (0...255).contains(number) && String(number) == part
              })
        else { return false }
        return true
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    private static func isValidName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 160 && !containsControlCharacters(value, allowingNewlines: false)
    }

    static func isValidModel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 256 && !containsControlCharacters(value, allowingNewlines: false)
    }

    private static func isValidReasoningEffort(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }

    private static func isValidReasoningEffortCapabilities(_ capabilities: ReasoningEffortCapabilities) -> Bool {
        isValidEndpoint(capabilities.endpoint)
            && isValidModel(capabilities.model)
            && (1...32).contains(capabilities.supportedEfforts.count)
            && Set(capabilities.supportedEfforts).count == capabilities.supportedEfforts.count
            && capabilities.supportedEfforts.allSatisfy(isValidReasoningEffort)
            && (capabilities.defaultEffort.map(isValidReasoningEffort) ?? true)
    }

    static func isValidInstruction(_ value: String) -> Bool {
        value.utf8.count <= 65_536 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !containsControlCharacters(value, allowingNewlines: true)
    }

    private static func containsControlCharacters(_ value: String, allowingNewlines: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            let code = scalar.value
            if allowingNewlines && (code == 9 || code == 10 || code == 13) { return false }
            return code < 32 || code == 127
        }
    }

    private struct ShortcutKey: Hashable {
        let keyCode: UInt16
        let command: Bool
        let option: Bool
        let control: Bool
        let shift: Bool

        init(_ shortcut: ShortcutBinding) {
            keyCode = shortcut.keyCode
            command = shortcut.command
            option = shortcut.option
            control = shortcut.control
            shift = shortcut.shift
        }
    }
}
