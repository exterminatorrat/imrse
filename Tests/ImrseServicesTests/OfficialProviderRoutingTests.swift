import Foundation
import XCTest
@testable import ImrseServices
import ImrseCore

final class OfficialProviderRoutingTests: XCTestCase {
    func testAccountPrimarySuppressesRemoteFallbacksButKeepsLocalFallbacks() throws {
        for kind in [ProviderKind.openAIChatGPT, .openRouterAccount, .huggingFaceAccount, .githubCopilot] {
            let primary = accountProvider(kind: kind, id: "primary")
            let remoteAccount = accountProvider(kind: .openRouterAccount, id: "remote-account")
            let local = ProviderConfiguration(
                id: "local",
                name: "Local",
                kind: .compatible,
                endpoint: URL(string: "http://127.0.0.1:11434/v1")!,
                model: "local-model",
                requiresCredential: false
            )
            let router = ProviderRouter(configuration: AppConfiguration(
                providers: [primary, remoteAccount, local],
                selectedProviderID: primary.id
            ))

            let accountFallback = try router.resolve(preset: Preset(
                id: "switch-account",
                name: "Switch account",
                instruction: "Rewrite",
                providerID: primary.id,
                fallbackProviderID: remoteAccount.id
            ))
            XCTAssertNil(accountFallback.fallback, "\(kind) must not silently change remote billing account")

            let localFallback = try router.resolve(preset: Preset(
                id: "local-fallback",
                name: "Local fallback",
                instruction: "Rewrite",
                providerID: primary.id,
                fallbackProviderID: local.id
            ))
            XCTAssertEqual(localFallback.fallback?.id, local.id)
        }
    }

    func testDirectRoutedProviderDoesNotSwitchRemoteAccountAndAllowsLocalFallback() async throws {
        let primary = accountProvider(kind: .huggingFaceAccount, id: "huggingface")
        let remote = accountProvider(kind: .openRouterAccount, id: "openrouter")
        let local = ProviderConfiguration(
            id: "local",
            name: "Local",
            kind: .compatible,
            endpoint: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "local-model",
            requiresCredential: false
        )

        let deniedSwitch = RecordingFallbackProvider(failPrimary: true)
        let deniedSwitchRoute = RoutedTextProvider(primary: deniedSwitch)
        await assertError(.network) {
            _ = try await collect(deniedSwitchRoute, request: request(primary: primary, fallback: remote))
        }
        let deniedSwitchIDs = await deniedSwitch.providerIDs()
        XCTAssertEqual(deniedSwitchIDs, [primary.id])

        let localFallbackProvider = RecordingFallbackProvider(failPrimary: true)
        let localFallbackRoute = RoutedTextProvider(primary: localFallbackProvider)
        let localOutput = try await collect(localFallbackRoute, request: request(primary: primary, fallback: local))
        XCTAssertEqual(localOutput, "local output")
        let localFallbackIDs = await localFallbackProvider.providerIDs()
        XCTAssertEqual(localFallbackIDs, [primary.id, local.id])
    }

    func testDispatchRoutesEachNewTransportKindToItsDedicatedProvider() async throws {
        let compatible = RecordingTextProvider(output: "compatible")
        let chatGPT = RecordingTextProvider(output: "chatgpt")
        let local = RecordingTextProvider(output: "local")
        let anthropic = RecordingTextProvider(output: "anthropic")
        let account = RecordingTextProvider(output: "account")
        let copilot = RecordingTextProvider(output: "copilot")
        let dispatch = ProviderDispatchProvider(
            compatible: compatible,
            account: chatGPT,
            local: local,
            anthropic: anthropic,
            officialAccount: account,
            copilot: copilot
        )
        let cases: [(ProviderConfiguration, String)] = [
            (compatibleProvider(), "compatible"),
            (accountProvider(kind: .openAIChatGPT, id: "chatgpt"), "chatgpt"),
            (ProviderConfiguration(
                id: "native-local",
                name: "Native local",
                kind: .managedLocal,
                endpoint: URL(string: "imrse-local://models")!,
                model: "local-model",
                requiresCredential: false
            ), "local"),
            (accountProvider(kind: .anthropic, id: "anthropic"), "anthropic"),
            (accountProvider(kind: .openRouterAccount, id: "openrouter"), "account"),
            (accountProvider(kind: .huggingFaceAccount, id: "huggingface"), "account"),
            (accountProvider(kind: .githubCopilot, id: "copilot"), "copilot")
        ]

        for (provider, output) in cases {
            let actual = try await collect(dispatch, request: request(primary: provider))
            XCTAssertEqual(actual, output)
        }
        let compatibleCalls = await compatible.calls()
        let chatGPTCalls = await chatGPT.calls()
        let localCalls = await local.calls()
        let anthropicCalls = await anthropic.calls()
        let accountCalls = await account.calls()
        let copilotCalls = await copilot.calls()
        XCTAssertEqual(compatibleCalls, 1)
        XCTAssertEqual(chatGPTCalls, 1)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(anthropicCalls, 1)
        XCTAssertEqual(accountCalls, 2)
        XCTAssertEqual(copilotCalls, 1)
    }

    func testLocalOnlyRejectsRemoteNewTransportKindsBeforeDispatch() async {
        for kind in [ProviderKind.anthropic, .openRouterAccount, .huggingFaceAccount, .githubCopilot] {
            let destination = RecordingTextProvider(output: "must not run")
            let dispatch = ProviderDispatchProvider(
                compatible: destination,
                anthropic: destination,
                officialAccount: destination,
                copilot: destination
            )
            await assertError(.localModelUnavailable) {
                _ = try await collect(dispatch, request: request(primary: accountProvider(kind: kind, id: "remote"), localOnly: true))
            }
            let calls = await destination.calls()
            XCTAssertEqual(calls, 0)
        }
    }

    private func request(
        primary: ProviderConfiguration,
        fallback: ProviderConfiguration? = nil,
        localOnly: Bool = false
    ) -> TransformationRequest {
        TransformationRequest(
            text: "selected",
            instruction: "rewrite",
            provider: primary,
            localOnly: localOnly,
            fallbackProvider: fallback
        )
    }
}

private func accountProvider(kind: ProviderKind, id: String) -> ProviderConfiguration {
    let endpoint: String
    switch kind {
    case .openAIChatGPT: endpoint = "https://api.openai.com/v1"
    case .anthropic: endpoint = "https://api.anthropic.com/v1"
    case .openRouterAccount: endpoint = "https://openrouter.ai/api/v1"
    case .huggingFaceAccount: endpoint = "https://router.huggingface.co/v1"
    case .githubCopilot: endpoint = "https://api.githubcopilot.com"
    default: fatalError("Not an account or Anthropic kind")
    }
    return ProviderConfiguration(id: id, name: id, kind: kind, endpoint: URL(string: endpoint)!, model: "manual-model-id")
}

private func compatibleProvider() -> ProviderConfiguration {
    ProviderConfiguration(
        id: "compatible",
        name: "Compatible",
        kind: .compatible,
        endpoint: URL(string: "https://api.example.com/v1")!,
        model: "manual-model-id"
    )
}

private func localProvider() -> ProviderConfiguration {
    ProviderConfiguration(
        id: "local",
        name: "Local",
        kind: .compatible,
        endpoint: URL(string: "http://127.0.0.1:11434/v1")!,
        model: "local-model",
        requiresCredential: false
    )
}

private actor RecordingTextProvider: TextProvider {
    private let output: String
    private var count = 0

    init(output: String) { self.output = output }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        count += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }

    func calls() -> Int { count }
}

private actor RecordingFallbackProvider: TextProvider {
    private let failPrimary: Bool
    private var usedIDs: [String] = []

    init(failPrimary: Bool) { self.failPrimary = failPrimary }

    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        usedIDs.append(request.provider.id)
        if failPrimary && request.provider.id == "huggingface" { throw ImrseError.network }
        return AsyncThrowingStream { continuation in
            continuation.yield("local output")
            continuation.finish()
        }
    }

    func providerIDs() -> [String] { usedIDs }
}

private func collect(_ provider: any TextProvider, request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    var output = ""
    for try await delta in stream { output += delta }
    return output
}

private func assertError(
    _ expected: ImrseError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ImrseError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), received \(error)", file: file, line: line)
    }
}
