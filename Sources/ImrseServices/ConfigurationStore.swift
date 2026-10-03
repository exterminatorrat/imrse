import Foundation
import ImrseCore

public struct ConfigurationStore: Sendable {
    public static let builtInDefaultInstruction = "Improve clarity, grammar, and structure while preserving intent, tone, technical terminology, and useful formatting. Be concise without removing important details. Do not invent facts or add assumptions. Return only the transformed text, without explanations or wrappers."

    private static let maximumConfigurationBytes = 262_144
    private static let maximumPresetBytes = 131_072
    private let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func load() throws -> AppConfiguration {
        try ensureRootDirectory(create: false)
        let configuration = try readConfiguration()
        let presets = try readPresets()
        try ProviderValidation.validateShortcuts(configuration: configuration, presets: presets)
        return configuration
    }

    public func save(_ configuration: AppConfiguration) throws {
        try ensureRootDirectory(create: true)
        try ensureManagedFile(configurationURL, error: .invalidConfiguration)
        try ProviderValidation.validate(configuration)
        let presets = try readPresets()
        try ProviderValidation.validateShortcuts(configuration: configuration, presets: presets)
        do {
            try write(encode(configuration), to: configurationURL)
        } catch let error as ImrseError {
            throw error
        } catch {
            throw ImrseError.invalidConfiguration
        }
    }

    public func loadDefaultInstruction() throws -> String {
        try ensureRootDirectory(create: false)
        guard let data = try readFile(at: defaultInstructionURL, limit: 65_536, error: .invalidConfiguration) else {
            return Self.builtInDefaultInstruction
        }
        guard let instruction = String(data: data, encoding: .utf8) else { throw ImrseError.invalidConfiguration }
        let normalized = instruction.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.builtInDefaultInstruction
            : normalized
    }

    public func saveDefaultInstruction(_ instruction: String) throws {
        try ensureRootDirectory(create: true)
        try ensureManagedFile(defaultInstructionURL, error: .invalidConfiguration)
        guard instruction.utf8.count <= 65_536,
              !instruction.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw ImrseError.invalidConfiguration }
        do {
            try write(Data(instruction.utf8), to: defaultInstructionURL)
        } catch {
            throw ImrseError.invalidConfiguration
        }
    }

    public func loadPresets() throws -> [Preset] {
        try ensureRootDirectory(create: false)
        let configuration = try readConfiguration()
        let presets = try readPresets()
        try ProviderValidation.validateShortcuts(configuration: configuration, presets: presets)
        return presets
    }

    public func savePreset(_ preset: Preset) throws {
        try ensureRootDirectory(create: true)
        try ProviderValidation.validate(preset)
        let configuration = try readConfiguration()
        let existing = try readPresets().filter { $0.id != preset.id }
        try ProviderValidation.validateShortcuts(configuration: configuration, presets: existing + [preset])

        let frontmatter = PresetFrontmatter(preset)
        do {
            let metadata = try encode(frontmatter)
            guard let metadataText = String(data: metadata, encoding: .utf8) else { throw ImrseError.invalidPreset }
            let content = "---\n\(metadataText)\n---\n\(preset.instruction)\n"
            guard content.utf8.count <= Self.maximumPresetBytes else { throw ImrseError.invalidPreset }
            try ensurePresetsDirectory(create: true)
            try write(Data(content.utf8), to: presetURL(id: frontmatter.id))
        } catch let error as ImrseError {
            throw error
        } catch {
            throw ImrseError.invalidPreset
        }
    }

    public func deletePreset(id: String) throws {
        try ensureRootDirectory(create: false)
        guard ProviderValidation.isValidIdentifier(id) else { throw ImrseError.invalidPreset }
        try ensurePresetsDirectory(create: false)
        let file = presetURL(id: id)
        guard try fileType(at: file, error: .invalidPreset) != nil else { return }
        guard try fileType(at: file, error: .invalidPreset) == .typeRegular else { throw ImrseError.invalidPreset }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw ImrseError.invalidPreset
        }
    }

    public func bootstrap() throws {
        do {
            try ensureRootDirectory(create: true)
            try ensurePresetsDirectory(create: true)
            let configurationType = try fileType(at: configurationURL)
            let instructionType = try fileType(at: defaultInstructionURL)
            guard configurationType == nil || configurationType == .typeRegular,
                  instructionType == nil || instructionType == .typeRegular
            else { throw ImrseError.invalidConfiguration }
            if configurationType == nil {
                try write(encode(AppConfiguration()), to: configurationURL)
            }
            if instructionType == nil {
                try write(Data((Self.builtInDefaultInstruction + "\n").utf8), to: defaultInstructionURL)
            }
        } catch let error as ImrseError {
            throw error
        } catch {
            throw ImrseError.invalidConfiguration
        }
    }

    private var configurationURL: URL { root.appending(path: "config.json") }
    private var defaultInstructionURL: URL { root.appending(path: "default.md") }
    private var presetsURL: URL { root.appending(path: "presets", directoryHint: .isDirectory) }

    private func presetURL(id: String) -> URL { presetsURL.appending(path: "\(id).md") }

    private func readConfiguration() throws -> AppConfiguration {
        guard let data = try readFile(at: configurationURL, limit: Self.maximumConfigurationBytes, error: .invalidConfiguration) else {
            return AppConfiguration()
        }
        do {
            let object = try requireKeys(
                JSONSerialization.jsonObject(with: data),
                allowed: ["version", "providers", "selectedProviderID", "invocation", "motion", "clipboardFallbackEnabled", "showInMenuBar", "appearance"],
                failure: .invalidConfiguration
            )
            if let providers = object["providers"] as? [Any] {
                for provider in providers {
                    _ = try requireKeys(provider, allowed: ["id", "name", "kind", "endpoint", "model", "requiresCredential"], failure: .invalidConfiguration)
                }
            }
            if let invocation = object["invocation"] {
                let fields = try requireKeys(invocation, allowed: ["doubleControlEnabled", "doubleControlInterval", "shortcut"], failure: .invalidConfiguration)
                try requireShortcutKeys(fields["shortcut"], failure: .invalidConfiguration)
            }
            let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
            try ProviderValidation.validate(configuration)
            return configuration
        } catch let error as ImrseError {
            throw error
        } catch {
            throw ImrseError.invalidConfiguration
        }
    }

    private func readPresets() throws -> [Preset] {
        try ensurePresetsDirectory(create: false)
        guard try fileType(at: presetsURL, error: .invalidPreset) != nil else { return [] }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: presetsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var presets: [Preset] = []
            for file in files where file.pathExtension.lowercased() == "md" {
                guard try fileType(at: file, error: .invalidPreset) == .typeRegular,
                      ProviderValidation.isValidIdentifier(file.deletingPathExtension().lastPathComponent)
                else { throw ImrseError.invalidPreset }
                guard let data = try readFile(at: file, limit: Self.maximumPresetBytes, error: .invalidPreset) else {
                    throw ImrseError.invalidPreset
                }
                let preset = try decodePreset(data)
                guard preset.id == file.deletingPathExtension().lastPathComponent else { throw ImrseError.invalidPreset }
                try ProviderValidation.validate(preset)
                presets.append(preset)
            }
            guard Set(presets.map(\.id)).count == presets.count else { throw ImrseError.invalidPreset }
            return presets.sorted { $0.id < $1.id }
        } catch let error as ImrseError {
            throw error
        } catch {
            throw ImrseError.invalidPreset
        }
    }

    private func decodePreset(_ data: Data) throws -> Preset {
        guard let markdown = String(data: data, encoding: .utf8) else { throw ImrseError.invalidPreset }
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---")
        else { throw ImrseError.invalidPreset }

        let metadataText = lines[1..<end].joined(separator: "\n")
        let bodyStart = end + 1
        let instructionLines = bodyStart < lines.count ? Array(lines[bodyStart...]) : []
        var instruction = instructionLines.joined(separator: "\n")
        if instruction.hasSuffix("\n") { instruction.removeLast() }

        do {
            let metadataData = Data(metadataText.utf8)
            let fields = try requireKeys(
                JSONSerialization.jsonObject(with: metadataData),
                allowed: ["id", "name", "providerID", "model", "localOnly", "fallbackProviderID", "shortcut", "motion", "context"],
                failure: .invalidPreset
            )
            try requireShortcutKeys(fields["shortcut"], failure: .invalidPreset)
            let metadata = try JSONDecoder().decode(PresetFrontmatter.self, from: metadataData)
            let preset = metadata.makePreset(instruction: instruction)
            try ProviderValidation.validate(preset)
            return preset
        } catch let error as ImrseError {
            throw error
        } catch {
            throw ImrseError.invalidPreset
        }
    }

    private func requireKeys(_ value: Any, allowed: Set<String>, failure: ImrseError) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed) else { throw failure }
        return object
    }

    private func requireShortcutKeys(_ value: Any?, failure: ImrseError) throws {
        guard let value, !(value is NSNull) else { return }
        _ = try requireKeys(value, allowed: ["keyCode", "command", "option", "control", "shift"], failure: failure)
    }

    private func readFile(at url: URL, limit: Int, error: ImrseError) throws -> Data? {
        guard let type = try fileType(at: url, error: error) else { return nil }
        guard type == .typeRegular else { throw error }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw error }
            return data
        } catch let caught as ImrseError {
            throw caught
        } catch {
            throw error
        }
    }

    private func fileType(at url: URL, error failure: ImrseError = .invalidConfiguration) throws -> FileAttributeType? {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return .typeSymbolicLink }
        guard FileManager.default.fileExists(atPath: url.path) else {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let type = attributes[.type] as? FileAttributeType { return type }
            } catch {
                return nil
            }
            return nil
        }
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch {
            throw failure
        }
    }

    private func ensureManagedFile(_ url: URL, error: ImrseError) throws {
        guard let type = try fileType(at: url, error: error), type != .typeRegular else { return }
        throw error
    }

    private func ensureRootDirectory(create: Bool) throws {
        let type: FileAttributeType?
        do {
            type = try fileType(at: root)
        } catch {
            throw ImrseError.invalidConfiguration
        }
        if type == nil, create {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw ImrseError.invalidConfiguration
            }
        } else if let type, type != .typeDirectory {
            throw ImrseError.invalidConfiguration
        }
    }

    private func ensurePresetsDirectory(create: Bool) throws {
        let type: FileAttributeType?
        do {
            type = try fileType(at: presetsURL, error: .invalidPreset)
        } catch {
            throw ImrseError.invalidPreset
        }
        if type == nil, create {
            do {
                try FileManager.default.createDirectory(at: presetsURL, withIntermediateDirectories: true)
            } catch {
                throw ImrseError.invalidPreset
            }
        } else if let type, type != .typeDirectory {
            throw ImrseError.invalidPreset
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}

private struct PresetFrontmatter: Codable {
    let id: String
    let name: String
    let providerID: String?
    let model: String?
    let localOnly: Bool
    let fallbackProviderID: String?
    let shortcut: ShortcutBinding?
    let motion: MotionPreference?
    let context: ContextScope

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        providerID = preset.providerID
        model = preset.model
        localOnly = preset.localOnly
        fallbackProviderID = preset.fallbackProviderID
        shortcut = preset.shortcut
        motion = preset.motion
        context = preset.context
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        providerID = try values.decodeIfPresent(String.self, forKey: .providerID)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        localOnly = try values.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        fallbackProviderID = try values.decodeIfPresent(String.self, forKey: .fallbackProviderID)
        shortcut = try values.decodeIfPresent(ShortcutBinding.self, forKey: .shortcut)
        motion = try values.decodeIfPresent(MotionPreference.self, forKey: .motion)
        context = try values.decodeIfPresent(ContextScope.self, forKey: .context) ?? .selection
    }

    func makePreset(instruction: String) -> Preset {
        Preset(
            id: id,
            name: name,
            instruction: instruction,
            providerID: providerID,
            model: model,
            localOnly: localOnly,
            fallbackProviderID: fallbackProviderID,
            shortcut: shortcut,
            motion: motion,
            context: context
        )
    }
}
