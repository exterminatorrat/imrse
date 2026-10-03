#if os(macOS) && DEBUG
import AppKit
import ImrseCore
import ImrseLocal
@testable import ImrseServices
import XCTest
@testable import ImrseApp

@MainActor
final class ModelSettingsTests: XCTestCase {
    func testPreviewLeavesModelControlsDisabledAndRejectsKeychainQueries() async {
        let model = AppModel(previewState: .settings)

        XCTAssertTrue(model.isPreviewMode)
        XCTAssertFalse(model.hasAccountRuntime)
        XCTAssertFalse(model.hasManagedLocalModelStore)
        XCTAssertTrue(model.managedLocalModelSnapshots.isEmpty)
        XCTAssertFalse(model.canChangeSettings)
        XCTAssertFalse(model.isTerminating)
        XCTAssertEqual(model.eventMonitoringStatus, "Not queried in preview")
        if let localModelID = ManagedLocalModelCatalog.models.first?.id {
            model.downloadManagedModel(localModelID)
        }
        XCTAssertNil(model.managedLocalModelDownloadID)
        XCTAssertFalse(model.isChangingManagedLocalModel)

        do {
            _ = try await model.hasCredential(for: "preview-provider")
            XCTFail("Preview mode must not query Keychain.")
        } catch {
            XCTAssertEqual(AppModel.userMessage(for: error), "Settings are read-only in preview mode.")
        }
    }

    func testUnsavedProviderDoesNotQueryKeychainForCredentialStatus() async throws {
        let model = AppModel(testEngine: makeEngine())

        let hasCredential = try await model.hasCredential(for: "unsaved-provider")

        XCTAssertFalse(hasCredential)
    }

    func testProviderReasoningCapabilitiesUseInjectedCatalog() async throws {
        let endpoint = URL(string: "https://custom.example/v1")!
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: "reported-model",
            supportedEfforts: ["high", "low"],
            requestFormat: .chatCompletionsField
        )
        let catalog = StaticProviderModelCatalogClient(capabilities: capabilities)
        let model = AppModel(testEngine: makeEngine(), providerModelCatalog: catalog)
        let provider = ProviderConfiguration(
            id: "custom-provider",
            name: "Custom provider",
            kind: .compatible,
            endpoint: endpoint,
            model: "reported-model",
            requiresCredential: false
        )

        let result = try await model.providerReasoningEffortCapabilities(for: provider)

        XCTAssertEqual(result, capabilities)
        let requestedProvider = await catalog.requestedProvider()
        XCTAssertEqual(requestedProvider, provider)
    }

    func testAuthenticatedCatalogDoesNotUseCredentialForUnsavedDestination() async {
        let savedEndpoint = URL(string: "https://saved.example/v1")!
        let changedEndpoint = URL(string: "https://changed.example/v1")!
        let savedProvider = ProviderConfiguration(
            id: "custom-provider",
            name: "Custom provider",
            kind: .compatible,
            endpoint: savedEndpoint,
            model: "model-1"
        )
        let credentiallessProvider = ProviderConfiguration(
            id: "credentialless-provider",
            name: "Credentialless provider",
            kind: .compatible,
            endpoint: URL(string: "https://credentialless.example/v1")!,
            model: "model-1",
            requiresCredential: false
        )
        let catalog = StaticProviderModelCatalogClient(capabilities: nil)
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(providers: [savedProvider, credentiallessProvider], selectedProviderID: savedProvider.id),
            providerModelCatalog: catalog
        )
        let changedProviders = [
            ProviderConfiguration(
                id: savedProvider.id,
                name: savedProvider.name,
                kind: savedProvider.kind,
                endpoint: changedEndpoint,
                model: savedProvider.model
            ),
            ProviderConfiguration(
                id: "different-provider",
                name: savedProvider.name,
                kind: savedProvider.kind,
                endpoint: savedEndpoint,
                model: savedProvider.model
            ),
            ProviderConfiguration(
                id: savedProvider.id,
                name: savedProvider.name,
                kind: .openRouter,
                endpoint: savedEndpoint,
                model: savedProvider.model
            ),
            ProviderConfiguration(
                id: credentiallessProvider.id,
                name: credentiallessProvider.name,
                kind: credentiallessProvider.kind,
                endpoint: credentiallessProvider.endpoint,
                model: credentiallessProvider.model,
                requiresCredential: true
            )
        ]

        for changedProvider in changedProviders {
            do {
                _ = try await model.providerReasoningEffortCapabilities(for: changedProvider)
                XCTFail("An unsaved authenticated destination must not reach the provider catalog.")
            } catch {
                XCTAssertEqual(error as? AppModelProviderModelCatalogError, .unsavedAuthenticatedDestination)
            }
        }

        let requestedProvider = await catalog.requestedProvider()
        XCTAssertNil(requestedProvider)
    }

    func testSavedAuthenticatedProviderCanQueryCatalog() async throws {
        let endpoint = URL(string: "https://custom.example/v1")!
        let provider = ProviderConfiguration(
            id: "saved-provider",
            name: "Saved provider",
            kind: .compatible,
            endpoint: endpoint,
            model: "model-1"
        )
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: provider.model,
            supportedEfforts: ["high"],
            requestFormat: .chatCompletionsField
        )
        let catalog = StaticProviderModelCatalogClient(capabilities: capabilities)
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: AppConfiguration(providers: [provider], selectedProviderID: provider.id),
            providerModelCatalog: catalog
        )

        let result = try await model.providerReasoningEffortCapabilities(for: provider)

        XCTAssertEqual(result, capabilities)
        let requestedProvider = await catalog.requestedProvider()
        XCTAssertEqual(requestedProvider, provider)
    }

    func testPublicOpenRouterCatalogCanBeQueriedBeforeSavingProvider() async throws {
        let endpoint = URL(string: "https://openrouter.ai/api/v1")!
        let provider = ProviderConfiguration(
            id: "new-router",
            name: "OpenRouter",
            kind: .openRouter,
            endpoint: endpoint,
            model: "model-1"
        )
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: provider.model,
            supportedEfforts: ["high"],
            requestFormat: .chatCompletionsObject
        )
        let catalog = StaticProviderModelCatalogClient(capabilities: capabilities)
        let model = AppModel(testEngine: makeEngine(), providerModelCatalog: catalog)

        let result = try await model.providerReasoningEffortCapabilities(for: provider)

        XCTAssertEqual(result, capabilities)
        let requestedProvider = await catalog.requestedProvider()
        XCTAssertEqual(requestedProvider, provider)
    }

    func testProviderReasoningCapabilityQueryRejectsLateCancelledResponse() async throws {
        let endpoint = URL(string: "https://custom.example/v1")!
        let capabilities = ReasoningEffortCapabilities(
            endpoint: endpoint,
            model: "reported-model",
            supportedEfforts: ["high"],
            requestFormat: .chatCompletionsField
        )
        let catalog = DeferredProviderModelCatalogClient(capabilities: capabilities)
        let model = AppModel(testEngine: makeEngine(), providerModelCatalog: catalog)
        let provider = ProviderConfiguration(
            id: "custom-provider",
            name: "Custom provider",
            kind: .compatible,
            endpoint: endpoint,
            model: "reported-model",
            requiresCredential: false
        )
        let query = Task { try await model.providerReasoningEffortCapabilities(for: provider) }
        try await catalog.waitForRequest()
        query.cancel()
        await catalog.finishPendingRequest()

        do {
            _ = try await query.value
            XCTFail("A cancelled capability query must not return its late result.")
        } catch is CancellationError {}
    }

    func testSavingProviderPreservesExistingProvidersAndPresetRouting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(root: root)
        try store.bootstrap()

        let existingProviders = [
            ProviderConfiguration(
                id: "legacy-openai",
                name: "Legacy OpenAI",
                kind: .openAI,
                endpoint: URL(string: "https://api.openai.com/v1")!,
                model: "legacy-model"
            ),
            ProviderConfiguration(
                id: "custom-endpoint",
                name: "Private endpoint",
                kind: .compatible,
                endpoint: URL(string: "https://example.com/v1")!,
                model: "private-model"
            ),
            ProviderConfiguration(
                id: "fallback-provider",
                name: "Fallback",
                kind: .openRouter,
                endpoint: URL(string: "https://openrouter.ai/api/v1")!,
                model: "fallback-model"
            )
        ]
        let configuration = AppConfiguration(
            providers: existingProviders,
            selectedProviderID: "custom-endpoint",
            invocation: InvocationConfiguration(
                doubleControlEnabled: false,
                doubleControlInterval: 0.45,
                shortcut: ShortcutBinding(keyCode: 40, command: true)
            ),
            motion: .instant,
            clipboardFallbackEnabled: true
        )
        let preset = Preset(
            id: "rewrite-selection",
            name: "Rewrite",
            instruction: "Rewrite this selection clearly.",
            providerID: "custom-endpoint",
            model: "preset-specific-model",
            fallbackProviderID: "fallback-provider",
            motion: .smooth
        )
        try store.save(configuration)
        try store.savePreset(preset)

        let model = AppModel(
            testEngine: makeEngine(),
            configuration: configuration,
            presets: [preset],
            configurationStore: store
        )
        let accountProvider = ProviderConfiguration(
            id: "chatgpt-account",
            name: "OpenAI ChatGPT account",
            kind: .openAIChatGPT,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-6-luna"
        )

        try model.saveProvider(accountProvider)

        var expectedConfiguration = configuration
        expectedConfiguration.providers.append(accountProvider)
        expectedConfiguration.selectedProviderID = accountProvider.id
        XCTAssertEqual(model.configuration, expectedConfiguration)
        XCTAssertEqual(model.presets, [preset])
        XCTAssertEqual(try store.load(), expectedConfiguration)
        XCTAssertEqual(try store.loadPresets(), [preset])
    }

    func testChatGPTProviderIDCollisionPreservesExistingProvider() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(root: root)
        try store.bootstrap()

        let existing = ProviderConfiguration(
            id: AppModel.defaultChatGPTProviderID,
            name: "Legacy compatible provider",
            kind: .compatible,
            endpoint: URL(string: "https://legacy.example/v1")!,
            model: "legacy-model"
        )
        let configuration = AppConfiguration(providers: [existing], selectedProviderID: existing.id)
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: configuration,
            configurationStore: store
        )
        let accountProvider = ProviderConfiguration(
            id: model.chatGPTProviderID,
            name: "OpenAI ChatGPT account",
            kind: .openAIChatGPT,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-6-luna"
        )

        XCTAssertNotEqual(accountProvider.id, existing.id)
        try model.saveProvider(accountProvider)

        XCTAssertEqual(model.configuration.providers, [existing, accountProvider])
        XCTAssertEqual(model.configuration.selectedProviderID, accountProvider.id)
        XCTAssertEqual(try store.load().providers, [existing, accountProvider])
    }

    func testTerminationDisablesSettingsBeforeReturningToTheSystem() throws {
        let model = AppModel(testEngine: makeEngine())
        XCTAssertFalse(model.hasManagedLocalModelStore)
        XCTAssertTrue(model.canChangeSettings)
        XCTAssertTrue(model.canOpenSettings)

        XCTAssertEqual(model.requestTermination { _ in }, .terminateNow)

        XCTAssertTrue(model.isTerminating)
        XCTAssertFalse(model.canChangeSettings)
        XCTAssertFalse(model.canOpenSettings)
        XCTAssertThrowsError(try model.saveConfiguration(model.configuration))
    }

    func testLateAccountStatusCompletionCannotReplaceNewerSessionState() async throws {
        let account = DelayedModelCatalogAccountClient()
        addTeardownBlock { await account.finishPendingRequests() }
        let model = AppModel(testEngine: makeEngine(), accountOperations: account)

        let staleRefresh = Task { await model.refreshChatGPTAccount() }
        try await account.waitForStatusCalls(1)
        let currentRefresh = Task { await model.refreshChatGPTAccount() }
        try await account.waitForStatusCalls(2)
        await currentRefresh.value
        XCTAssertEqual(model.chatGPTStatus?.isConnected, false)

        await account.finishStatusRequest()
        await staleRefresh.value

        XCTAssertEqual(model.chatGPTStatus?.isConnected, false)
        XCTAssertNil(model.chatGPTIssue)
        XCTAssertFalse(model.isConnectingChatGPT)
    }

    func testChatGPTChoicesUseEveryReportedModelWithoutChangingUnlistedSavedModel() async {
        let configuredProvider = ProviderConfiguration(
            id: "chatgpt-account",
            name: "OpenAI ChatGPT account",
            kind: .openAIChatGPT,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            model: "configured-model-not-listed"
        )
        let configuration = AppConfiguration(
            providers: [configuredProvider],
            selectedProviderID: configuredProvider.id
        )
        let reportedModels = [
            OpenAIAccountModel(slug: "model-zeta", displayName: "Model Zeta"),
            OpenAIAccountModel(slug: "model-alpha", displayName: "Model Alpha")
        ]
        let account = StaticModelCatalogAccountClient(models: reportedModels)
        let model = AppModel(
            testEngine: makeEngine(),
            configuration: configuration,
            accountOperations: account
        )

        await model.refreshChatGPTAccount()

        XCTAssertEqual(model.chatGPTRecommendations.map(\.id), ["model-zeta", "model-alpha"])
        XCTAssertEqual(model.chatGPTRecommendations.map(\.name), ["Model Zeta", "Model Alpha"])
        XCTAssertEqual(model.chatGPTRecommendations.map(\.detail), [
            "Returned by your ChatGPT account",
            "Returned by your ChatGPT account"
        ])
        XCTAssertEqual(model.configuration.providers, [configuredProvider])
        XCTAssertEqual(model.configuration.selectedProviderID, configuredProvider.id)
        XCTAssertNil(model.chatGPTIssue)
        XCTAssertFalse(model.isRefreshingChatGPTAccount)
    }

    func testRemovingAccountProviderDisconnectsItsGrantWithoutChangingOtherProviders() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "imrse-account-removal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(root: directory)
        let accountProvider = ProviderConfiguration(
            id: "account", name: "ChatGPT account", kind: .openAIChatGPT,
            endpoint: URL(string: "https://api.openai.com/v1")!, model: "gpt-test"
        )
        let apiProvider = ProviderConfiguration(
            id: "api", name: "OpenAI API", kind: .openAI,
            endpoint: URL(string: "https://api.openai.com/v1")!, model: "gpt-test"
        )
        let configuration = AppConfiguration(providers: [accountProvider, apiProvider], selectedProviderID: accountProvider.id)
        try store.save(configuration)
        let account = DelayedModelCatalogAccountClient()
        let model = AppModel(testEngine: makeEngine(), configuration: configuration, configurationStore: store, accountOperations: account)

        try await model.deleteProvider(id: accountProvider.id)

        let disconnected = await account.disconnectedProviderIDs()
        XCTAssertEqual(disconnected, [accountProvider.id])
        XCTAssertEqual(model.configuration.providers, [apiProvider])
        XCTAssertEqual(try store.load().providers, [apiProvider])
        XCTAssertNil(model.configuration.selectedProviderID)
        XCTAssertEqual(model.chatGPTStatus?.isConnected, false)
        XCTAssertFalse(model.isDisconnectingChatGPT)
    }

    func testReferencedAccountProviderCannotBeDisconnectedByRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "imrse-account-referenced-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(root: directory)
        let provider = ProviderConfiguration(
            id: "account", name: "ChatGPT account", kind: .openAIChatGPT,
            endpoint: URL(string: "https://api.openai.com/v1")!, model: "gpt-test"
        )
        let configuration = AppConfiguration(providers: [provider], selectedProviderID: provider.id)
        try store.save(configuration)
        let account = DelayedModelCatalogAccountClient()
        let model = AppModel(
            testEngine: makeEngine(), configuration: configuration,
            presets: [Preset(id: "rewrite", name: "Rewrite", instruction: "Rewrite.", fallbackProviderID: provider.id)],
            configurationStore: store, accountOperations: account
        )

        do {
            try await model.deleteProvider(id: provider.id)
            XCTFail("Referenced account removal must be rejected")
        } catch {
            XCTAssertEqual(model.configuration, configuration)
            XCTAssertEqual(try store.load(), configuration)
        }
        let disconnected = await account.disconnectedProviderIDs()
        XCTAssertTrue(disconnected.isEmpty)
    }

    func testLateAccountModelCatalogCannotOverwriteNewerSignInOrClearItsState() async throws {
        let account = DelayedModelCatalogAccountClient()
        addTeardownBlock { await account.finishPendingRequests() }
        let coordinator = ImmediateChatGPTSignInCoordinator()
        let model = AppModel(
            testEngine: makeEngine(),
            accountOperations: account,
            signInCoordinator: coordinator
        )

        model.connectChatGPTAccount()
        let firstTask = try XCTUnwrap(model.chatGPTSignInTaskForTesting)
        try await account.waitForModelRequests(1)
        let firstAttempt = await account.attemptID(at: 0)
        let firstAttemptID = try XCTUnwrap(firstAttempt)

        model.cancelChatGPTSignIn()
        model.connectChatGPTAccount()
        let secondTask = try XCTUnwrap(model.chatGPTSignInTaskForTesting)
        try await account.waitForModelRequests(2)
        let secondAttempt = await account.attemptID(at: 1)
        let secondAttemptID = try XCTUnwrap(secondAttempt)
        XCTAssertNotEqual(firstAttemptID, secondAttemptID)

        await account.finishModelRequest(1)
        await firstTask.value

        XCTAssertTrue(model.isConnectingChatGPT)
        XCTAssertNotNil(model.chatGPTSignInTaskForTesting)
        XCTAssertTrue(model.chatGPTModels.isEmpty)

        await account.finishModelRequest(2)
        await secondTask.value

        XCTAssertFalse(model.isConnectingChatGPT)
        XCTAssertEqual(model.chatGPTModels.map(\.slug), ["current-model"])
        try await account.waitForCancellation(of: firstAttemptID)
        let cancelledAttemptIDs = await account.allCancelledAttemptIDs()
        let activeAttemptID = await account.currentAttemptID()
        XCTAssertEqual(cancelledAttemptIDs, [firstAttemptID])
        XCTAssertEqual(activeAttemptID, secondAttemptID)
        XCTAssertEqual(coordinator.cancellationCount, 1)
    }

    private func makeEngine() -> TransformationEngine {
        TransformationEngine(selectionAccess: ModelTestSelectionAccess(), textProvider: ModelTestTextProvider())
    }
}

@MainActor
private final class ModelTestSelectionAccess: SelectionAccess {
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

private struct ModelTestTextProvider: TextProvider {
    func stream(_ request: TransformationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor DelayedModelCatalogAccountClient: AppModelOpenAIAccountClient {
    private var attemptIDs: [UUID] = []
    private var cancelledAttempts: [UUID] = []
    private var activeAttempt: UUID?
    private var disconnectedProviders: [String] = []
    private var statusRequestCount = 0
    private var modelRequestCount = 0
    private var statusContinuation: CheckedContinuation<OpenAIAccountStatus, Never>?
    private var modelContinuations: [Int: CheckedContinuation<[OpenAIAccountModel], Never>] = [:]
    private var hasCompletedFixture = false

    func connectionStatus(for providerID: String) async throws -> OpenAIAccountStatus {
        statusRequestCount += 1
        if statusRequestCount == 1, !hasCompletedFixture {
            return await withCheckedContinuation { statusContinuation = $0 }
        }
        return OpenAIAccountStatus(isConnected: false, canUseChatGPTPlan: false, accountLabel: nil)
    }

    func prepareSignIn(for providerID: String, redirectURI: URL) async throws -> OpenAISignInRequest {
        let attemptID = UUID()
        attemptIDs.append(attemptID)
        activeAttempt = attemptID
        return OpenAISignInRequest(
            attemptID: attemptID,
            authorizationURL: URL(string: "https://auth.openai.com/api/accounts/authorize")!
        )
    }

    func completeSignIn(for providerID: String, callbackURL: URL) async throws -> OpenAIAccountStatus {
        OpenAIAccountStatus(isConnected: true, canUseChatGPTPlan: true, accountLabel: "Test account")
    }

    func cancelSignIn(for providerID: String, attemptID: UUID) {
        cancelledAttempts.append(attemptID)
        if activeAttempt == attemptID { activeAttempt = nil }
    }

    func disconnect(for providerID: String) async throws { disconnectedProviders.append(providerID) }

    func disconnectedProviderIDs() -> [String] { disconnectedProviders }

    func availableModels(for providerID: String) async throws -> [OpenAIAccountModel] {
        modelRequestCount += 1
        let requestID = modelRequestCount
        guard !hasCompletedFixture else { return [] }
        return await withCheckedContinuation { modelContinuations[requestID] = $0 }
    }

    func finishStatusRequest() {
        let continuation = statusContinuation
        statusContinuation = nil
        continuation?.resume(returning: OpenAIAccountStatus(
            isConnected: true, canUseChatGPTPlan: true, accountLabel: "Stale account"
        ))
    }

    func finishModelRequest(_ requestID: Int) {
        let slug = requestID == 1 ? "stale-model" : "current-model"
        let title = requestID == 1 ? "Stale Model" : "Current Model"
        modelContinuations.removeValue(forKey: requestID)?.resume(returning: [
            OpenAIAccountModel(slug: slug, displayName: title)
        ])
    }

    func finishPendingRequests() {
        hasCompletedFixture = true
        finishStatusRequest()
        for requestID in Array(modelContinuations.keys) { finishModelRequest(requestID) }
    }

    func attemptID(at index: Int) -> UUID? {
        guard attemptIDs.indices.contains(index) else { return nil }
        return attemptIDs[index]
    }

    func allCancelledAttemptIDs() -> [UUID] { cancelledAttempts }

    func currentAttemptID() -> UUID? { activeAttempt }

    func waitForStatusCalls(_ count: Int) async throws {
        for _ in 0..<200 {
            if statusRequestCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModelSettingsFixtureError.timedOut
    }

    func waitForModelRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if modelRequestCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModelSettingsFixtureError.timedOut
    }

    func waitForCancellation(of attemptID: UUID) async throws {
        for _ in 0..<200 {
            if cancelledAttempts.contains(attemptID) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModelSettingsFixtureError.timedOut
    }
}

private actor StaticModelCatalogAccountClient: AppModelOpenAIAccountClient {
    private let models: [OpenAIAccountModel]

    init(models: [OpenAIAccountModel]) {
        self.models = models
    }

    func connectionStatus(for providerID: String) async throws -> OpenAIAccountStatus {
        OpenAIAccountStatus(isConnected: true, canUseChatGPTPlan: true, accountLabel: "Test account")
    }

    func prepareSignIn(for providerID: String, redirectURI: URL) async throws -> OpenAISignInRequest {
        throw ModelSettingsFixtureError.timedOut
    }

    func completeSignIn(for providerID: String, callbackURL: URL) async throws -> OpenAIAccountStatus {
        OpenAIAccountStatus(isConnected: true, canUseChatGPTPlan: true, accountLabel: "Test account")
    }

    func cancelSignIn(for providerID: String, attemptID: UUID) {}

    func disconnect(for providerID: String) async throws {}

    func availableModels(for providerID: String) async throws -> [OpenAIAccountModel] {
        models
    }
}

private enum ModelSettingsFixtureError: Error {
    case timedOut
}

private actor StaticProviderModelCatalogClient: AppModelProviderModelCatalogClient {
    private let capabilities: ReasoningEffortCapabilities?
    private var requested: ProviderConfiguration?

    init(capabilities: ReasoningEffortCapabilities?) {
        self.capabilities = capabilities
    }

    func reasoningEffortCapabilities(for provider: ProviderConfiguration) async throws -> ReasoningEffortCapabilities? {
        requested = provider
        return capabilities
    }

    func requestedProvider() -> ProviderConfiguration? { requested }
}

private actor DeferredProviderModelCatalogClient: AppModelProviderModelCatalogClient {
    private let capabilities: ReasoningEffortCapabilities?
    private var requestStarted = false
    private var continuation: CheckedContinuation<ReasoningEffortCapabilities?, any Error>?

    init(capabilities: ReasoningEffortCapabilities?) {
        self.capabilities = capabilities
    }

    func reasoningEffortCapabilities(for provider: ProviderConfiguration) async throws -> ReasoningEffortCapabilities? {
        requestStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitForRequest() async throws {
        for _ in 0..<200 {
            if requestStarted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ModelSettingsFixtureError.timedOut
    }

    func finishPendingRequest() {
        continuation?.resume(returning: capabilities)
        continuation = nil
    }
}

@MainActor
private final class ImmediateChatGPTSignInCoordinator: AppModelChatGPTSignInCoordinating {
    private(set) var cancellationCount = 0

    func prepareCallback() async throws -> URL {
        URL(string: "http://127.0.0.1:1455/auth/callback")!
    }

    func openAndWait(for authorizationURL: URL, timeout: Duration) async throws -> URL {
        URL(string: "http://127.0.0.1:1455/auth/callback?code=test")!
    }

    func cancel() {
        cancellationCount += 1
    }
}
#endif
