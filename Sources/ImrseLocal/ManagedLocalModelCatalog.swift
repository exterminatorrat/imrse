import Foundation

public struct ManagedLocalModelDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let revision: String
    public let license: String
    public let downloadBytes: Int64
    public let minimumMemoryBytes: Int64?
}

public struct ManagedLocalModelSnapshot: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        case downloading(Int64)
        case installed
    }

    public let descriptor: ManagedLocalModelDescriptor
    public let state: State
    public var id: String { descriptor.id }
}

struct ManagedLocalModelArtifact: Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

struct ManagedLocalModelManifest: Sendable {
    let descriptor: ManagedLocalModelDescriptor
    let storageName: String
    let artifacts: [ManagedLocalModelArtifact]
}

public enum ManagedLocalRuntimeAvailability: Sendable, Equatable {
    case available
    case requiresAppleSilicon
}

public enum ManagedLocalModelCatalog {
    static let manifests = [
        ManagedLocalModelManifest(
            descriptor: .init(
                id: "mlx-community/Qwen3-1.7B-4bit",
                title: "Qwen3 1.7B · 4-bit",
                detail: "Compact instruction model for private, on-device text transformations.",
                revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
                license: "Apache-2.0",
                downloadBytes: 984_013_244,
                minimumMemoryBytes: nil
            ),
            storageName: "qwen3-1.7b-4bit",
            artifacts: [
                .init(path: "added_tokens.json", byteCount: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
                .init(path: "config.json", byteCount: 937, sha256: "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
                .init(path: "merges.txt", byteCount: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
                .init(path: "model.safetensors", byteCount: 968_080_210, sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
                .init(path: "model.safetensors.index.json", byteCount: 49_731, sha256: "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15"),
                .init(path: "special_tokens_map.json", byteCount: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
                .init(path: "tokenizer.json", byteCount: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                .init(path: "tokenizer_config.json", byteCount: 9_706, sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
                .init(path: "vocab.json", byteCount: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")
            ]
        ),
        ManagedLocalModelManifest(
            descriptor: .init(
                id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
                title: "Qwen3 4B Instruct · 4-bit",
                detail: "Balanced instruction model for private, on-device text transformations.",
                revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
                license: "Apache-2.0",
                downloadBytes: 2_278_969_697,
                minimumMemoryBytes: nil
            ),
            storageName: "qwen3-4b-instruct-2507-4bit",
            artifacts: [
                .init(path: "added_tokens.json", byteCount: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
                .init(path: "config.json", byteCount: 938, sha256: "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"),
                .init(path: "merges.txt", byteCount: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
                .init(path: "model.safetensors", byteCount: 2_263_022_417, sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"),
                .init(path: "model.safetensors.index.json", byteCount: 63_964, sha256: "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777"),
                .init(path: "special_tokens_map.json", byteCount: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
                .init(path: "tokenizer.json", byteCount: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                .init(path: "tokenizer_config.json", byteCount: 5_440, sha256: "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"),
                .init(path: "vocab.json", byteCount: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
                .init(path: "chat_template.jinja", byteCount: 4_040, sha256: "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"),
                .init(path: "generation_config.json", byteCount: 238, sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48")
            ]
        )
    ]
    public static let models = manifests.map(\.descriptor)
    public static let minimumMacOSVersion = "14.0"
    #if arch(arm64)
    public static let runtimeAvailability: ManagedLocalRuntimeAvailability = .available
    #else
    public static let runtimeAvailability: ManagedLocalRuntimeAvailability = .requiresAppleSilicon
    #endif

    public static func model(id: String) -> ManagedLocalModelDescriptor? {
        models.first { $0.id == id }
    }
}
