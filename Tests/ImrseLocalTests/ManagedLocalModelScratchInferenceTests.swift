#if os(macOS) && arch(arm64)
import Foundation
import ImrseCore
import XCTest
@testable import ImrseLocal

final class ManagedLocalModelScratchInferenceTests: XCTestCase {
    func testCompactModelTransformsTextFromVerificationScratchRoot() async throws {
        guard ProcessInfo.processInfo.environment["IMRSE_RUN_QWEN3_SCRATCH"] == "1" else {
            throw XCTSkip("Set IMRSE_RUN_QWEN3_SCRATCH=1 to run the authorized compact-model download and inference check")
        }

        let environment = ProcessInfo.processInfo.environment
        guard let verificationRootPath = environment["IMRSE_VERIFICATION_ROOT"],
              let verificationHomePath = environment["CFFIXED_USER_HOME"]
        else {
            throw XCTSkip("Set IMRSE_VERIFICATION_ROOT and CFFIXED_USER_HOME to keep the model under verification scratch")
        }
        let verificationRoot = URL(fileURLWithPath: verificationRootPath, isDirectory: true).standardizedFileURL
        let verificationHome = URL(fileURLWithPath: verificationHomePath, isDirectory: true).standardizedFileURL
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
        guard verificationHome.path.hasPrefix(verificationRoot.path + "/"),
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL == verificationHome,
              applicationSupport.path.hasPrefix(verificationRoot.path + "/")
        else {
            XCTFail("The managed-model store must resolve inside verification scratch")
            return
        }

        let modelID = "mlx-community/Qwen3-1.7B-4bit"
        let store = ManagedLocalModelStore()
        try await store.download(modelID: modelID)
        let provider = ManagedLocalTextProvider(store: store)
        let request = TransformationRequest(
            text: "teh quick brown fox.",
            instruction: "Correct only the misspelling 'teh' to 'the'. Return exactly 'the quick brown fox.'.",
            provider: ProviderConfiguration(
                id: "local",
                name: "Local model",
                kind: .managedLocal,
                endpoint: URL(string: "imrse-local://models")!,
                model: modelID,
                requiresCredential: false
            ),
            localOnly: true
        )

        let generation = try await provider.generateCompletion(for: request)

        XCTAssertEqual(generation.termination, .stop)
        XCTAssertLessThan(generation.generationTokenCount, ManagedLocalGenerationLimits.maximumGeneratedTokens)
        XCTAssertEqual(generation.text, "the quick brown fox.", "A length-truncated generation must not be accepted as complete.")
        XCTAssertFalse(generation.text.localizedCaseInsensitiveContains("<think>"))
        XCTAssertFalse(generation.text.localizedCaseInsensitiveContains("</think>"))
    }
}
#endif
