import XCTest
@testable import ImrseLocal

final class ManagedLocalModelCatalogTests: XCTestCase {
    func testCatalogPinsTwoQwenInstructModelsAndEveryRuntimeArtifact() throws {
        let compact = try XCTUnwrap(ManagedLocalModelCatalog.model(id: "mlx-community/Qwen3-1.7B-4bit"))
        let balanced = try XCTUnwrap(ManagedLocalModelCatalog.model(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit"))

        XCTAssertEqual(compact.revision, "3b1b1768f8f8cf8351c712464f906e86c2b8269e")
        XCTAssertEqual(compact.downloadBytes, 984_013_244)
        XCTAssertEqual(compact.license, "Apache-2.0")
        XCTAssertNil(compact.minimumMemoryBytes)
        XCTAssertEqual(balanced.revision, "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")
        XCTAssertEqual(balanced.downloadBytes, 2_278_969_697)
        XCTAssertEqual(balanced.license, "Apache-2.0")
        XCTAssertNil(balanced.minimumMemoryBytes)

        XCTAssertEqual(ManagedLocalModelCatalog.manifests.map(\.artifacts).first?.map(artifactDescription), [
            "added_tokens.json|707|c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680",
            "config.json|937|507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7",
            "merges.txt|1671853|8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
            "model.safetensors|968080210|0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f",
            "model.safetensors.index.json|49731|1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15",
            "special_tokens_map.json|613|76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd",
            "tokenizer.json|11422654|aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
            "tokenizer_config.json|9706|253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0",
            "vocab.json|2776833|ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
        ])
        XCTAssertEqual(ManagedLocalModelCatalog.manifests.map(\.artifacts).last?.map(artifactDescription), [
            "added_tokens.json|707|c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680",
            "config.json|938|574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849",
            "merges.txt|1671853|8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
            "model.safetensors|2263022417|2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f",
            "model.safetensors.index.json|63964|388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777",
            "special_tokens_map.json|613|76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd",
            "tokenizer.json|11422654|aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
            "tokenizer_config.json|5440|4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9",
            "vocab.json|2776833|ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
            "chat_template.jinja|4040|40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541",
            "generation_config.json|238|835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"
        ])
    }

    func testRuntimeAvailabilityReportsAppleSiliconAndMacOSRequirement() {
        XCTAssertEqual(ManagedLocalModelCatalog.minimumMacOSVersion, "14.0")
        #if arch(arm64)
        XCTAssertEqual(ManagedLocalModelCatalog.runtimeAvailability, .available)
        #else
        XCTAssertEqual(ManagedLocalModelCatalog.runtimeAvailability, .requiresAppleSilicon)
        #endif
    }

    private func artifactDescription(_ artifact: ManagedLocalModelArtifact) -> String {
        "\(artifact.path)|\(artifact.byteCount)|\(artifact.sha256)"
    }
}
