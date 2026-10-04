#if os(macOS) && DEBUG
import AppKit
import Foundation
import ImrseCore
@testable import ImrseServices
import XCTest
@testable import ImrseApp

@MainActor
final class OfficialAccountSettingsTests: XCTestCase {
    func testAccountRegistrationDoesNotReplaceTheDefaultUntilModelIsSaved() throws {
        let existing = ProviderConfiguration(
            id: "existing-provider",
            name: "Existing provider",
            kind: .openAI,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-test",
            requiresCredential: false
        )
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(providers: [existing], selectedProviderID: existing.id),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountClient: OfficialAccountClient(credentials: MemoryCredentials(), transport: ScriptedTransport())
        )
        let account = accountProvider(.openRouterAccount, id: "openrouter", model: "__select_model__")

        try model.saveOfficialAccountRegistration(account)

        XCTAssertEqual(model.configuration.providers.last, account)
        XCTAssertEqual(model.configuration.selectedProviderID, existing.id)

        try model.saveProvider(accountProvider(.openRouterAccount, id: account.id, model: "openai/model"))

        XCTAssertEqual(model.configuration.selectedProviderID, account.id)
        XCTAssertEqual(model.configuration.providers.first(where: { $0.id == account.id })?.model, "openai/model")
    }

    func testCancellingBrowserSignInClearsThePendingAttemptWithoutStoringCredentials() async throws {
        let credentials = MemoryCredentials()
        let provider = accountProvider(.openRouterAccount, id: "openrouter", model: "__select_model__")
        let coordinator = DeferredOfficialAccountSignInCoordinator()
        let model = AppModel(
            testEngine: makeEngine(),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountClient: OfficialAccountClient(credentials: credentials, transport: ScriptedTransport()),
            officialAccountSignInCoordinator: coordinator
        )

        model.connectOfficialAccount(provider)
        try await coordinator.waitForOpenAndWait()
        model.cancelOfficialAccountSignIn(for: provider.id)
        try await waitUntil { !model.isConnectingOfficialAccount(for: provider.id) }

        XCTAssertGreaterThan(coordinator.cancellationCount, 0)
        let savedCredential = try await credentials.credential(for: "oauth:openRouterAccount:\(provider.id)")
        XCTAssertNil(savedCredential)
        XCTAssertTrue(model.configuration.providers.contains(where: { $0.id == provider.id }))
    }

    func testRemovingOfficialAccountClearsItsNamespacedCredentialAndConfiguration() async throws {
        let credentials = MemoryCredentials()
        let provider = accountProvider(.openRouterAccount, id: "openrouter", model: "openai/model")
        let apiProvider = ProviderConfiguration(
            id: "openrouter-api",
            name: "OpenRouter API key",
            kind: .openRouter,
            endpoint: URL(string: "https://openrouter.ai/api/v1")!,
            model: "openai/model"
        )
        try await credentials.setCredential("synthetic-account-token", for: "oauth:openRouterAccount:\(provider.id)")
        try await credentials.setCredential("synthetic-api-key", for: apiProvider.id)
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(providers: [provider, apiProvider], selectedProviderID: provider.id),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountClient: OfficialAccountClient(credentials: credentials, transport: ScriptedTransport())
        )

        try await model.deleteProvider(id: provider.id)

        let savedCredential = try await credentials.credential(for: "oauth:openRouterAccount:\(provider.id)")
        let savedAPIKey = try await credentials.credential(for: apiProvider.id)
        XCTAssertNil(savedCredential)
        XCTAssertFalse(model.configuration.providers.contains(where: { $0.id == provider.id }))
        XCTAssertEqual(savedAPIKey, "synthetic-api-key")
        XCTAssertTrue(model.configuration.providers.contains(where: { $0.id == apiProvider.id }))
        XCTAssertNil(model.configuration.selectedProviderID)
    }

    func testPreviewNeverStartsOfficialAccountAuthentication() {
        let model = AppModel(previewState: .settings)
        let provider = accountProvider(.githubCopilot, id: "copilot", clientID: "public-client")

        model.connectOfficialAccount(provider)

        XCTAssertFalse(model.hasOfficialAccountClient)
        XCTAssertFalse(model.isConnectingOfficialAccount(for: provider.id))
        XCTAssertTrue(model.officialAccountStatuses.isEmpty)
    }

    func testCancelledSignInDrainsAttemptCleanupBeforeStartingAnotherAttempt() async throws {
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let client = ControlledOfficialAccountClient(holdAuthorizationCleanup: true)
        let coordinator = LifecycleOfficialAccountSignInCoordinator()
        let model = AppModel(
            testEngine: makeEngine(),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountOperations: client,
            officialAccountSignInCoordinator: coordinator
        )

        model.connectOfficialAccount(provider)
        try await coordinator.waitForOpenCount(1)
        model.cancelOfficialAccountSignIn(for: provider.id)
        try await client.waitForAuthorizationCleanupCount(1)

        model.connectOfficialAccount(provider)
        let beginCountDuringCleanup = await client.authorizationBeginCount()
        XCTAssertEqual(beginCountDuringCleanup, 1)
        XCTAssertTrue(model.isConnectingOfficialAccount(for: provider.id))

        let attemptIDs = await client.authorizationAttemptIDs()
        let firstAttemptID = attemptIDs[0]
        let firstCleanupIDs = await client.authorizationCleanupAttemptIDs()
        XCTAssertEqual(firstCleanupIDs, [Optional(firstAttemptID)])
        await client.releaseAuthorizationCleanup()
        try await waitUntil { !model.isConnectingOfficialAccount(for: provider.id) }

        model.connectOfficialAccount(provider)
        try await coordinator.waitForOpenCount(2)
        let beginCountAfterCleanup = await client.authorizationBeginCount()
        XCTAssertEqual(beginCountAfterCleanup, 2)
        model.cancelOfficialAccountSignIn(for: provider.id)
        try await waitUntil { !model.isConnectingOfficialAccount(for: provider.id) }
    }

    func testTerminationWaitsForSignInAuthorizationCleanup() async throws {
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let client = ControlledOfficialAccountClient(holdAuthorizationCleanup: true)
        let coordinator = LifecycleOfficialAccountSignInCoordinator()
        let model = AppModel(
            testEngine: makeEngine(),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountOperations: client,
            officialAccountSignInCoordinator: coordinator
        )
        model.connectOfficialAccount(provider)
        try await coordinator.waitForOpenCount(1)
        var terminationReply: NSApplication.TerminateReply?

        let decision = model.requestTermination { terminationReply = $0 }

        XCTAssertEqual(decision, .terminateLater)
        XCTAssertNil(terminationReply)
        try await client.waitForAuthorizationCleanupCount(1)
        XCTAssertNil(terminationReply)
        await client.releaseAuthorizationCleanup()
        try await waitUntil { terminationReply == .terminateNow }

        let cleanupIDs = await client.authorizationCleanupAttemptIDs()
        let attemptIDs = await client.authorizationAttemptIDs()
        XCTAssertEqual(cleanupIDs, [Optional(attemptIDs[0])])
        XCTAssertFalse(model.isConnectingOfficialAccount(for: provider.id))
    }

    func testTerminationWaitsForSignInModelFetchAndDiscardsItsResult() async throws {
        let provider = accountProvider(.openRouterAccount, id: "openrouter")
        let client = ControlledOfficialAccountClient(
            connectionStatus: OfficialAccountConnectionStatus(isConnected: true, accountLabel: "test"),
            holdAvailableModels: true
        )
        let coordinator = LifecycleOfficialAccountSignInCoordinator()
        let model = AppModel(
            testEngine: makeEngine(),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountOperations: client,
            officialAccountSignInCoordinator: coordinator
        )
        model.connectOfficialAccount(provider)
        try await coordinator.waitForOpenCount(1)
        coordinator.completeOpen(with: URL(string: "http://127.0.0.1:48320/auth/callback?code=code&state=state")!)
        try await client.waitForAvailableModelsCount(1)
        var terminationReply: NSApplication.TerminateReply?

        let decision = model.requestTermination { terminationReply = $0 }

        XCTAssertEqual(decision, .terminateLater)
        XCTAssertNil(terminationReply)
        await client.releaseAvailableModels()
        try await waitUntil { terminationReply == .terminateNow }

        XCTAssertNil(model.officialAccountModels[provider.id])
    }

    func testTerminationWaitsForDisconnectCredentialDeletion() async throws {
        let credentials = MemoryCredentials()
        let provider = accountProvider(.openRouterAccount, id: "openrouter", model: "openai/model")
        let credentialID = "oauth:openRouterAccount:\(provider.id)"
        try await credentials.setCredential("synthetic-account-token", for: credentialID)
        let client = ControlledOfficialAccountClient(credentials: credentials, holdDisconnect: true)
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(providers: [provider], selectedProviderID: provider.id),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountOperations: client
        )
        model.disconnectOfficialAccount(for: provider.id)
        try await client.waitForDisconnectCount(1)
        var terminationReply: NSApplication.TerminateReply?

        let decision = model.requestTermination { terminationReply = $0 }

        XCTAssertEqual(decision, .terminateLater)
        XCTAssertNil(terminationReply)
        await client.releaseDisconnect()
        try await waitUntil { terminationReply == .terminateNow }

        let savedCredential = try await credentials.credential(for: credentialID)
        XCTAssertNil(savedCredential)
    }

    func testTerminationWaitsForAccountRemovalConfigurationRollback() async throws {
        let credentials = MemoryCredentials()
        let provider = accountProvider(.openRouterAccount, id: "openrouter", model: "openai/model")
        let credentialID = "oauth:openRouterAccount:\(provider.id)"
        try await credentials.setCredential("synthetic-account-token", for: credentialID)
        let client = ControlledOfficialAccountClient(
            credentials: credentials,
            holdDisconnect: true,
            failDisconnect: true
        )
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(providers: [provider], selectedProviderID: provider.id),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountOperations: client
        )
        let deletion = Task { try await model.deleteProvider(id: provider.id) }
        try await client.waitForDisconnectCount(1)
        XCTAssertFalse(model.configuration.providers.contains(where: { $0.id == provider.id }))
        var terminationReply: NSApplication.TerminateReply?

        let decision = model.requestTermination { terminationReply = $0 }

        XCTAssertEqual(decision, .terminateLater)
        XCTAssertNil(terminationReply)
        await client.releaseDisconnect()
        do {
            try await deletion.value
            XCTFail("Account removal should fail when credential deletion fails")
        } catch {}
        try await waitUntil { terminationReply == .terminateNow }

        XCTAssertTrue(model.configuration.providers.contains(where: { $0.id == provider.id }))
        let savedCredential = try await credentials.credential(for: credentialID)
        XCTAssertEqual(savedCredential, "synthetic-account-token")
    }

    func testAccountRemovalFailurePreservesUnrelatedConfigurationChanges() async throws {
        let credentials = MemoryCredentials()
        let provider = accountProvider(.openRouterAccount, id: "openrouter", model: "openai/model")
        let credentialID = "oauth:openRouterAccount:\(provider.id)"
        let alternative = ProviderConfiguration(
            id: "alternative",
            name: "Alternative",
            kind: .openAI,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-test",
            requiresCredential: false
        )
        let added = ProviderConfiguration(
            id: "added-during-removal",
            name: "Added during removal",
            kind: .anthropic,
            endpoint: URL(string: "https://api.anthropic.com/v1")!,
            model: "claude-test"
        )
        try await credentials.setCredential("synthetic-account-token", for: credentialID)
        let client = ControlledOfficialAccountClient(
            credentials: credentials,
            holdDisconnect: true,
            failDisconnect: true
        )
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(
                providers: [provider, alternative],
                selectedProviderID: provider.id
            ),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountOperations: client
        )
        let deletion = Task { try await model.deleteProvider(id: provider.id) }
        try await client.waitForDisconnectCount(1)
        var concurrentConfiguration = model.configuration
        concurrentConfiguration.providers.append(added)
        concurrentConfiguration.selectedProviderID = alternative.id
        concurrentConfiguration.appearance = .dark
        try model.saveConfiguration(concurrentConfiguration)
        await client.releaseDisconnect()
        do {
            try await deletion.value
            XCTFail("Account removal should fail when credential deletion fails")
        } catch {}

        XCTAssertEqual(model.configuration.providers.first(where: { $0.id == provider.id }), provider)
        XCTAssertTrue(model.configuration.providers.contains(where: { $0.id == alternative.id }))
        XCTAssertTrue(model.configuration.providers.contains(where: { $0.id == added.id }))
        XCTAssertEqual(model.configuration.selectedProviderID, alternative.id)
        XCTAssertEqual(model.configuration.appearance, .dark)
        let savedCredential = try await credentials.credential(for: credentialID)
        XCTAssertEqual(savedCredential, "synthetic-account-token")
    }

    func testClientIDChangeDuringRefreshDiscardsOldBindingModels() async throws {
        let provider = accountProvider(.huggingFaceAccount, id: "huggingface", clientID: "old-client")
        let client = ControlledOfficialAccountClient(
            connectionStatus: OfficialAccountConnectionStatus(isConnected: true, accountLabel: "test"),
            holdAvailableModels: true
        )
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(providers: [provider]),
            configurationStore: ConfigurationStore(root: temporaryDirectory()),
            officialAccountOperations: client
        )

        model.refreshOfficialAccount(for: provider)
        try await client.waitForAvailableModelsCount(1)
        let updatedProvider = accountProvider(.huggingFaceAccount, id: provider.id, clientID: "new-client")
        try model.saveOfficialAccountRegistration(updatedProvider)
        await client.releaseAvailableModels()
        try await waitUntil { !model.hasPendingOfficialAccountOperationsForTesting }

        XCTAssertNil(model.officialAccountStatus(for: provider))
        XCTAssertNil(model.officialAccountStatus(for: updatedProvider))
        XCTAssertTrue(model.officialAccountModels(for: updatedProvider).isEmpty)
        XCTAssertNil(model.officialAccountModels[provider.id])
    }

    private func makeEngine() -> TransformationEngine {
        TransformationEngine(selectionAccess: FixtureSelectionAccess(), textProvider: FixtureTextProvider())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private func accountProvider(
    _ kind: ProviderKind,
    id: String,
    model: String = "__select_model__",
    clientID: String? = nil
) -> ProviderConfiguration {
    let endpoint: URL
    switch kind {
    case .openRouterAccount:
        endpoint = URL(string: "https://openrouter.ai/api/v1")!
    case .huggingFaceAccount:
        endpoint = URL(string: "https://router.huggingface.co/v1")!
    default:
        endpoint = URL(string: "https://api.githubcopilot.com")!
    }
    return ProviderConfiguration(
        id: id,
        name: "\(kind.rawValue) account",
        kind: kind,
        endpoint: endpoint,
        model: model,
        oauthClientID: clientID
    )
}

@MainActor
private final class FixtureSelectionAccess: SelectionAccess {
    func capture() throws -> SelectionSnapshot {
        SelectionSnapshot(applicationID: "test", processID: 1, role: "textField", text: "selected")
    }

    func validate(_ target: SelectionSnapshot) throws {}

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {}

    func discard(_ target: SelectionSnapshot) {}
}

private struct FixtureTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor MemoryCredentials: CredentialStore {
    private var values: [String: String] = [:]

    func credential(for providerID: String) async throws -> String? { values[providerID] }
    func setCredential(_ value: String?, for providerID: String) async throws { values[providerID] = value }
}

private actor ScriptedTransport: StreamingHTTPTransport {
    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        throw CancellationError()
    }
}

@MainActor
private final class DeferredOfficialAccountSignInCoordinator: AppModelOfficialAccountSignInCoordinating {
    private(set) var cancellationCount = 0
    private var openContinuation: CheckedContinuation<URL, any Error>?
    private var didStartOpen = false

    func prepareCallback() async throws -> URL {
        URL(string: "http://127.0.0.1:48320/auth/callback")!
    }

    func openAndWait(for authorizationURL: URL, timeout: Duration) async throws -> URL {
        didStartOpen = true
        return try await withCheckedThrowingContinuation { openContinuation = $0 }
    }

    func openDeviceVerificationPage(for url: URL) -> Bool { true }

    func cancel() {
        cancellationCount += 1
        openContinuation?.resume(throwing: CancellationError())
        openContinuation = nil
    }

    func waitForOpenAndWait() async throws {
        for _ in 0..<200 {
            if didStartOpen { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OfficialAccountSettingsFixtureError.timedOut
    }
}

@MainActor
private final class LifecycleOfficialAccountSignInCoordinator: AppModelOfficialAccountSignInCoordinating {
    private(set) var openCount = 0
    private var openContinuations: [CheckedContinuation<URL, any Error>] = []

    func prepareCallback() async throws -> URL {
        URL(string: "http://127.0.0.1:48320/auth/callback")!
    }

    func openAndWait(for authorizationURL: URL, timeout: Duration) async throws -> URL {
        openCount += 1
        return try await withCheckedThrowingContinuation { openContinuations.append($0) }
    }

    func openDeviceVerificationPage(for url: URL) -> Bool { true }

    func cancel() {
        let continuations = openContinuations
        openContinuations = []
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    func completeOpen(with callbackURL: URL) {
        guard !openContinuations.isEmpty else { return }
        openContinuations.removeFirst().resume(returning: callbackURL)
    }

    func waitForOpenCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if openCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OfficialAccountSettingsFixtureError.timedOut
    }
}

private actor ControlledOfficialAccountClient: AppModelOfficialAccountClient {
    private let credentials: MemoryCredentials?
    private let status: OfficialAccountConnectionStatus
    private var holdsAuthorizationCleanup: Bool
    private var holdsAvailableModels: Bool
    private var holdsDisconnect: Bool
    private let failDisconnect: Bool
    private var beginCount = 0
    private var attempts: [UUID] = []
    private var cleanupAttempts: [UUID?] = []
    private var modelCalls = 0
    private var disconnectCalls = 0
    private var authorizationCleanupContinuation: CheckedContinuation<Void, Never>?
    private var availableModelsContinuation: CheckedContinuation<Void, Never>?
    private var disconnectContinuation: CheckedContinuation<Void, Never>?

    init(
        credentials: MemoryCredentials? = nil,
        connectionStatus: OfficialAccountConnectionStatus = OfficialAccountConnectionStatus(isConnected: false, accountLabel: nil),
        holdAuthorizationCleanup: Bool = false,
        holdAvailableModels: Bool = false,
        holdDisconnect: Bool = false,
        failDisconnect: Bool = false
    ) {
        self.credentials = credentials
        self.status = connectionStatus
        self.holdsAuthorizationCleanup = holdAuthorizationCleanup
        self.holdsAvailableModels = holdAvailableModels
        self.holdsDisconnect = holdDisconnect
        self.failDisconnect = failDisconnect
    }

    func beginAuthorization(
        for provider: ProviderConfiguration,
        redirectURI: URL?
    ) async throws -> OfficialAccountAuthorizationStart {
        guard let redirectURI else { throw OfficialAccountClientError.invalidConfiguration }
        beginCount += 1
        let attemptID = UUID()
        attempts.append(attemptID)
        return .browser(
            authorizationURL: URL(string: "https://example.invalid/authorize")!,
            callbackURL: redirectURI,
            attemptID: attemptID
        )
    }

    func completeAuthorization(
        for provider: ProviderConfiguration,
        callbackURL: URL
    ) async throws -> OfficialAccountConnectionStatus {
        status
    }

    func completeDeviceAuthorization(
        for provider: ProviderConfiguration,
        attemptID: UUID
    ) async throws -> OfficialAccountConnectionStatus {
        status
    }

    func cancelAuthorizationAndWait(for provider: ProviderConfiguration, attemptID: UUID?) async {
        cleanupAttempts.append(attemptID)
        guard holdsAuthorizationCleanup else { return }
        await withCheckedContinuation { authorizationCleanupContinuation = $0 }
    }

    func connectionStatus(for provider: ProviderConfiguration) async throws -> OfficialAccountConnectionStatus {
        status
    }

    func availableModels(for provider: ProviderConfiguration) async throws -> [OfficialAccountModel] {
        modelCalls += 1
        if holdsAvailableModels {
            await withCheckedContinuation { availableModelsContinuation = $0 }
        }
        return [OfficialAccountModel(id: "test/model", displayName: "Test model")]
    }

    func disconnect(for provider: ProviderConfiguration) async throws {
        disconnectCalls += 1
        if holdsDisconnect {
            await withCheckedContinuation { disconnectContinuation = $0 }
        }
        if failDisconnect { throw OfficialAccountClientError.storageUnavailable }
        try await credentials?.setCredential(nil, for: "oauth:\(provider.kind.rawValue):\(provider.id)")
    }

    func authorizationBeginCount() -> Int { beginCount }
    func authorizationAttemptIDs() -> [UUID] { attempts }
    func authorizationCleanupAttemptIDs() -> [UUID?] { cleanupAttempts }

    func waitForAuthorizationCleanupCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if cleanupAttempts.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OfficialAccountSettingsFixtureError.timedOut
    }

    func releaseAuthorizationCleanup() {
        holdsAuthorizationCleanup = false
        authorizationCleanupContinuation?.resume()
        authorizationCleanupContinuation = nil
    }

    func waitForAvailableModelsCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if modelCalls >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OfficialAccountSettingsFixtureError.timedOut
    }

    func releaseAvailableModels() {
        holdsAvailableModels = false
        availableModelsContinuation?.resume()
        availableModelsContinuation = nil
    }

    func waitForDisconnectCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if disconnectCalls >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OfficialAccountSettingsFixtureError.timedOut
    }

    func releaseDisconnect() {
        holdsDisconnect = false
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }
}

private enum OfficialAccountSettingsFixtureError: Error {
    case timedOut
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw OfficialAccountSettingsFixtureError.timedOut
}
#endif
