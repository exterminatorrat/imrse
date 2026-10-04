#if os(macOS)
import AppKit
import Combine
import Dispatch
import Foundation
import ImrseCore
import ImrseLocal
import ImrseMac
import ImrsePillUI
import ImrseServices
import OSLog

protocol AppModelOpenAIAccountClient: Actor {
    func connectionStatus(for providerID: String) async throws -> OpenAIAccountStatus
    func prepareSignIn(for providerID: String, redirectURI: URL) async throws -> OpenAISignInRequest
    func completeSignIn(for providerID: String, callbackURL: URL) async throws -> OpenAIAccountStatus
    func cancelSignIn(for providerID: String, attemptID: UUID)
    func disconnect(for providerID: String) async throws
    func availableModels(for providerID: String) async throws -> [OpenAIAccountModel]
}

extension OpenAIAccountClient: AppModelOpenAIAccountClient {}

protocol AppModelProviderModelCatalogClient: Sendable {
    func reasoningEffortCapabilities(for provider: ProviderConfiguration) async throws -> ReasoningEffortCapabilities?
}

extension ProviderModelCatalogClient: AppModelProviderModelCatalogClient {}

enum AppModelProviderModelCatalogError: Error, LocalizedError, Equatable {
    case unsavedAuthenticatedDestination

    var errorDescription: String? {
        "Save this provider before checking endpoint-advertised reasoning choices."
    }
}

@MainActor
protocol AppModelChatGPTSignInCoordinating: AnyObject {
    func prepareCallback() async throws -> URL
    func openAndWait(for authorizationURL: URL, timeout: Duration) async throws -> URL
    func cancel()
}

extension OpenAIChatGPTSignInCoordinator: AppModelChatGPTSignInCoordinating {}

@MainActor
protocol AppModelOfficialAccountSignInCoordinating: AnyObject {
    func prepareCallback() async throws -> URL
    func openAndWait(for authorizationURL: URL, timeout: Duration) async throws -> URL
    func openDeviceVerificationPage(for url: URL) -> Bool
    func cancel()
}

extension OfficialAccountSignInCoordinator: AppModelOfficialAccountSignInCoordinating {}

protocol AppModelOfficialAccountClient: Actor {
    func beginAuthorization(for provider: ProviderConfiguration, redirectURI: URL?) async throws -> OfficialAccountAuthorizationStart
    func completeAuthorization(for provider: ProviderConfiguration, callbackURL: URL) async throws -> OfficialAccountConnectionStatus
    func completeDeviceAuthorization(for provider: ProviderConfiguration, attemptID: UUID) async throws -> OfficialAccountConnectionStatus
    func cancelAuthorizationAndWait(for provider: ProviderConfiguration, attemptID: UUID?) async
    func connectionStatus(for provider: ProviderConfiguration) async throws -> OfficialAccountConnectionStatus
    func availableModels(for provider: ProviderConfiguration) async throws -> [OfficialAccountModel]
    func disconnect(for provider: ProviderConfiguration) async throws
}

extension OfficialAccountClient: AppModelOfficialAccountClient {
    func cancelAuthorizationAndWait(for provider: ProviderConfiguration, attemptID: UUID?) async {
        cancelAuthorization(for: provider, attemptID: attemptID)
    }
}

private struct OfficialAccountProviderBinding: Equatable {
    let id: String
    let kind: ProviderKind
    let endpoint: URL
    let clientID: String?

    init(_ provider: ProviderConfiguration) {
        id = provider.id
        kind = provider.kind
        endpoint = provider.endpoint
        clientID = provider.oauthClientID
    }
}

@MainActor
protocol ShortcutMonitoring: AnyObject {
    var isMonitoring: Bool { get }
    func start(
        configuration: InvocationConfiguration,
        presets: [Preset],
        onInvoke: @escaping @MainActor (String?) -> Void
    ) throws
    func stop()
}

extension ShortcutMonitor: ShortcutMonitoring {}

private enum ManagedLocalModelInstallAction: Sendable {
    case download
    case repair
}

@MainActor
final class AppModel: ObservableObject {
    let configurationStore: ConfigurationStore
    let credentialStore: KeychainCredentialStore
    let selectionAccess: MacSelectionAccess
    let engine: TransformationEngine
    let pillModel: PillModel
    private let pillBridge: AppPillBridge
    let shortcutMonitor: any ShortcutMonitoring

    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var defaultInstruction: String
    @Published private(set) var presets: [Preset]
    @Published private(set) var state = TransformationState.idle
    private(set) var latestResponseMetadata: ResponseMetadata?
    @Published private(set) var isRecordingShortcut = false
    @Published private(set) var configurationIssue: String?
    @Published private(set) var shortcutIssue: String?
    @Published private(set) var diagnosticsCopiedMessage: String?
    @Published private(set) var isTerminating = false
    @Published private(set) var chatGPTStatus: OpenAIAccountStatus?
    @Published private(set) var chatGPTModels: [OpenAIAccountModel] = []
    @Published private(set) var chatGPTIssue: String?
    @Published private(set) var isConnectingChatGPT = false
    @Published private(set) var isDisconnectingChatGPT = false
    @Published private(set) var isRefreshingChatGPTAccount = false
    @Published private(set) var officialAccountStatuses: [String: OfficialAccountConnectionStatus] = [:]
    @Published private(set) var officialAccountModels: [String: [OfficialAccountModel]] = [:]
    @Published private(set) var officialAccountIssues: [String: String] = [:]
    @Published private(set) var officialAccountRefreshingProviderID: String?
    @Published private(set) var officialAccountSigningInProviderID: String?
    @Published private(set) var officialAccountDisconnectingProviderIDs: Set<String> = []
    @Published private(set) var officialAccountSignInCancellationRequestedProviderID: String?
    @Published private(set) var officialAccountDeviceCode: String?
    @Published private(set) var officialAccountDeviceVerificationURL: URL?
    @Published private(set) var officialAccountDeviceCodeExpiresAt: Date?
    @Published private(set) var managedLocalModelSnapshots: [ManagedLocalModelSnapshot] = []
    @Published private(set) var managedLocalModelDownloadID: String?
    @Published private(set) var managedLocalModelProgress: ManagedLocalModelProgress?
    @Published private(set) var managedLocalModelIssue: String?
    @Published private(set) var isChangingManagedLocalModel = false

    var onPresentPill: (@MainActor (NSScreen?) -> Void)?
    #if DEBUG
    private(set) var previewState: AppPreviewState?
    #endif

    private var undoTask: Task<Void, Never>?
    private var terminationReplies: [@MainActor (NSApplication.TerminateReply) -> Void] = []
    private var terminationRequested = false
    private let connectedChatGPTProviderID: String
    private let openAIAccountClient: (any AppModelOpenAIAccountClient)?
    private let officialAccountClient: (any AppModelOfficialAccountClient)?
    private var officialAccountStatusBindings: [String: OfficialAccountProviderBinding] = [:]
    private let providerModelCatalogClient: any AppModelProviderModelCatalogClient
    private let chatGPTSignInCoordinator: (any AppModelChatGPTSignInCoordinating)?
    private let officialAccountSignInCoordinator: (any AppModelOfficialAccountSignInCoordinating)?
    private let copilotRuntime: (any CopilotRuntime)?
    private let managedLocalModelStore: ManagedLocalModelStore?
    private var accountStatusRefreshTask: Task<Void, Never>?
    private var chatGPTSignInTask: Task<Void, Never>?
    private var officialAccountStatusRefreshTask: Task<Void, Never>?
    private var officialAccountStatusRefreshSessionID: UUID?
    private var officialAccountStatusRefreshTaskID: UUID?
    private var officialAccountSignInTask: Task<Void, Never>?
    private var officialAccountSignInSessionID: UUID?
    private var officialAccountAttemptID: UUID?
    private var officialAccountSignInProvider: ProviderConfiguration?
    private var officialAccountDisconnectTasks: [String: Task<Void, Never>] = [:]
    private var officialAccountDisconnectTaskIDs: [String: UUID] = [:]
    private var officialAccountOperationIDs: Set<UUID> = []
    private var officialAccountDeletionProviderIDs: Set<String> = []
    private var managedLocalModelOperationTask: Task<Void, Never>?
    private var managedLocalModelOperationSessionID: UUID?
    private var chatGPTSignInSessionID: UUID?
    private var chatGPTAccountAttemptID: UUID?
    private var accountStatusSessionID: UUID?
    private var pendingClipboardFallback: Bool?
    private var shortcutMonitorRefreshPending = false
    private var shortcutRecordingSessionID: UUID?
    private(set) var shortcutMonitorActivationEpoch: UInt64 = 0
    private let allowsGlobalShortcutMonitoring: Bool
    private let lifecycleLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "imrse", category: "lifecycle")
    private var lifecycleStartedAt: Date?

    var canUndo: Bool { engine.canUndo && undoTask == nil }

    var canOpenSettings: Bool { !isTerminating && undoTask == nil && state != .replacing && state != .undoing }

    var canChangeSettings: Bool {
        !isPreviewMode && !isTerminating && configurationIssue == nil && !isProcessing
    }

    var chatGPTRecommendations: [CuratedModelChoice] {
        guard chatGPTStatus?.isConnected == true, chatGPTStatus?.canUseChatGPTPlan == true else { return [] }
        return chatGPTModels.map {
            CuratedModelChoice(
                id: $0.slug,
                name: $0.displayName,
                detail: "Returned by your ChatGPT account"
            )
        }
    }

    var chatGPTProviderID: String { connectedChatGPTProviderID }

    #if DEBUG
    var isPreviewMode: Bool { previewState != nil }
    #else
    var isPreviewMode: Bool { false }
    #endif

    var accessibilityStatus: String {
        isPreviewMode ? "Not queried in preview" : MacSelectionAccess.accessibilityPermissionGranted ? "Allowed" : "Required"
    }

    var eventMonitoringStatus: String {
        if isPreviewMode { return "Not queried in preview" }
        return isRecordingShortcut ? "Paused while recording" : shortcutMonitor.isMonitoring ? "Active" : "Inactive"
    }

    var shouldShowKeyboardMonitoringRetry: Bool {
        allowsGlobalShortcutMonitoring && !isPreviewMode && !isRecordingShortcut && !shortcutMonitor.isMonitoring
    }

    var canRetryKeyboardMonitoring: Bool {
        shouldShowKeyboardMonitoringRetry && configurationIssue == nil && !isProcessing && !isTerminating && !terminationRequested
    }

    var isProcessing: Bool {
        if undoTask != nil { return true }
        #if DEBUG
        if previewState == .generating || previewState == .replacing { return true }
        #endif
        return switch state {
        case .generating, .replacing, .undoing: true
        default: false
        }
    }

    #if DEBUG
    convenience init(previewState: AppPreviewState? = nil) {
        self.init(
            loadSettingsFromDisk: previewState == nil,
            isPreviewMode: previewState != nil,
            configurationOverride: previewState == nil ? nil : Self.previewConfiguration,
            presetsOverride: previewState == nil ? nil : Self.previewPresets
        )
        self.previewState = previewState
    }

    convenience init(
        testEngine: TransformationEngine,
        configuration: AppConfiguration = AppConfiguration(),
        presets: [Preset] = [],
        configurationStore: ConfigurationStore? = nil,
        shortcutMonitoring: (any ShortcutMonitoring)? = nil,
        accountClient: OpenAIAccountClient? = nil,
        accountOperations: (any AppModelOpenAIAccountClient)? = nil,
        signInCoordinator: (any AppModelChatGPTSignInCoordinating)? = nil,
        officialAccountClient: OfficialAccountClient? = nil,
        officialAccountOperations: (any AppModelOfficialAccountClient)? = nil,
        officialAccountSignInCoordinator: (any AppModelOfficialAccountSignInCoordinating)? = nil,
        providerModelCatalog: (any AppModelProviderModelCatalogClient)? = nil
    ) {
        self.init(
            loadSettingsFromDisk: false,
            isPreviewMode: false,
            configurationOverride: configuration,
            presetsOverride: presets,
            engineOverride: testEngine,
            configurationStoreOverride: configurationStore,
            shortcutMonitorOverride: shortcutMonitoring,
            accountClientOverride: accountClient,
            accountOperationsOverride: accountOperations,
            signInCoordinatorOverride: signInCoordinator,
            officialAccountClientOverride: officialAccountClient,
            officialAccountOperationsOverride: officialAccountOperations,
            officialAccountSignInCoordinatorOverride: officialAccountSignInCoordinator,
            providerModelCatalogOverride: providerModelCatalog
        )
    }
    #else
    convenience init() {
        self.init(loadSettingsFromDisk: true, isPreviewMode: false)
    }
    #endif

    private init(
        loadSettingsFromDisk: Bool,
        isPreviewMode: Bool,
        configurationOverride: AppConfiguration? = nil,
        presetsOverride: [Preset]? = nil,
        engineOverride: TransformationEngine? = nil,
        configurationStoreOverride: ConfigurationStore? = nil,
        shortcutMonitorOverride: (any ShortcutMonitoring)? = nil,
        accountClientOverride: OpenAIAccountClient? = nil,
        accountOperationsOverride: (any AppModelOpenAIAccountClient)? = nil,
        signInCoordinatorOverride: (any AppModelChatGPTSignInCoordinating)? = nil,
        officialAccountClientOverride: OfficialAccountClient? = nil,
        officialAccountOperationsOverride: (any AppModelOfficialAccountClient)? = nil,
        officialAccountSignInCoordinatorOverride: (any AppModelOfficialAccountSignInCoordinating)? = nil,
        providerModelCatalogOverride: (any AppModelProviderModelCatalogClient)? = nil
    ) {
        let store = configurationStoreOverride ?? ConfigurationStore(root: Self.applicationSupportURL)
        var configuration = AppConfiguration()
        var defaultInstruction = ConfigurationStore.builtInDefaultInstruction
        var presets: [Preset] = []
        var issue: String?

        if let configurationOverride {
            configuration = configurationOverride
            presets = presetsOverride ?? []
        } else if loadSettingsFromDisk {
            do {
                try store.bootstrap()
                configuration = try store.load()
                defaultInstruction = try store.loadDefaultInstruction()
                presets = try store.loadPresets()
            } catch {
                issue = Self.userMessage(for: error)
            }
        }

        let credentialStore = KeychainCredentialStore()
        let pillModel = PillModel(onSubmit: { _ in })
        let managedLocalModelStore: ManagedLocalModelStore?
        if !isPreviewMode && engineOverride == nil && ManagedLocalModelCatalog.runtimeAvailability == .available {
            managedLocalModelStore = ManagedLocalModelStore()
        } else {
            managedLocalModelStore = nil
        }
        let selectionAccess = MacSelectionAccess(
            clipboardFallbackEnabled: configuration.clipboardFallbackEnabled,
            prepareForClipboardPaste: { [weak pillModel] in pillModel?.dismiss() }
        )
        let runtimeAccountClient: OpenAIAccountClient?
        let accountClient: (any AppModelOpenAIAccountClient)?
        let signInCoordinator: (any AppModelChatGPTSignInCoordinating)?
        let connectedChatGPTProviderID = configuration.providers.first(where: { $0.kind == .openAIChatGPT })?.id
            ?? Self.uniqueProviderID(candidate: Self.defaultChatGPTProviderID, existingProviders: configuration.providers)
        if !isPreviewMode && engineOverride == nil {
            runtimeAccountClient = accountClientOverride ?? OpenAIAccountClient(credentials: credentialStore)
            accountClient = accountOperationsOverride ?? runtimeAccountClient
            signInCoordinator = signInCoordinatorOverride ?? OpenAIChatGPTSignInCoordinator()
        } else {
            runtimeAccountClient = accountClientOverride
            accountClient = accountOperationsOverride ?? accountClientOverride
            signInCoordinator = signInCoordinatorOverride
        }
        let runtimeOfficialAccountClient: OfficialAccountClient?
        let officialAccountOperationsClient: (any AppModelOfficialAccountClient)?
        let officialAccountSignInCoordinator: (any AppModelOfficialAccountSignInCoordinating)?
        if !isPreviewMode && engineOverride == nil {
            runtimeOfficialAccountClient = officialAccountClientOverride ?? OfficialAccountClient(credentials: credentialStore)
            officialAccountOperationsClient = officialAccountOperationsOverride ?? runtimeOfficialAccountClient
            officialAccountSignInCoordinator = officialAccountSignInCoordinatorOverride ?? OfficialAccountSignInCoordinator()
        } else {
            runtimeOfficialAccountClient = officialAccountClientOverride
            officialAccountOperationsClient = officialAccountOperationsOverride ?? officialAccountClientOverride
            officialAccountSignInCoordinator = officialAccountSignInCoordinatorOverride
        }
        let copilotRuntime: (any CopilotRuntime)?
        if !isPreviewMode, engineOverride == nil, let executableURL = Self.copilotRuntimeExecutableURL() {
            copilotRuntime = CopilotProcessRuntime(executableURL: executableURL)
        } else {
            copilotRuntime = nil
        }
        let compatibleProvider = OpenAICompatibleProvider(credentials: credentialStore)
        let anthropicProvider = AnthropicTextProvider(credentials: credentialStore)
        let accountProvider = runtimeAccountClient.map { OpenAIResponsesTextProvider(accountClient: $0) }
        let officialAccountProvider = runtimeOfficialAccountClient.map { OfficialAccountTextProvider(accountClient: $0) }
        let copilotProvider: CopilotTextProvider?
        if let runtimeOfficialAccountClient, let copilotRuntime {
            copilotProvider = CopilotTextProvider(
                accountClient: runtimeOfficialAccountClient,
                runtime: copilotRuntime
            )
        } else {
            copilotProvider = nil
        }
        let localProvider = managedLocalModelStore.map { ManagedLocalTextProvider(store: $0) }
        let dispatchProvider = ProviderDispatchProvider(
            compatible: compatibleProvider,
            account: accountProvider,
            local: localProvider,
            anthropic: anthropicProvider,
            officialAccount: officialAccountProvider,
            copilot: copilotProvider
        )
        let textProvider = RoutedTextProvider(primary: dispatchProvider)
        let engine = engineOverride ?? TransformationEngine(selectionAccess: selectionAccess, textProvider: textProvider)
        let pillBridge = AppPillBridge(
            engine: engine,
            pill: pillModel,
            configuration: configuration,
            defaultInstruction: defaultInstruction,
            presets: presets,
            screenAfterCapture: { selectionAccess.capturedScreen },
            fallbackScreen: Self.screenUnderPointer
        )

        self.configurationStore = store
        self.credentialStore = credentialStore
        self.selectionAccess = selectionAccess
        self.engine = engine
        self.pillModel = pillModel
        self.pillBridge = pillBridge
        self.shortcutMonitor = shortcutMonitorOverride ?? ShortcutMonitor()
        self.configuration = configuration
        self.defaultInstruction = defaultInstruction
        self.presets = presets
        self.configurationIssue = issue
        self.connectedChatGPTProviderID = connectedChatGPTProviderID
        self.openAIAccountClient = accountClient
        self.officialAccountClient = officialAccountOperationsClient
        self.providerModelCatalogClient = providerModelCatalogOverride ?? ProviderModelCatalogClient(credentials: credentialStore)
        self.chatGPTSignInCoordinator = signInCoordinator
        self.officialAccountSignInCoordinator = officialAccountSignInCoordinator
        self.copilotRuntime = copilotRuntime
        self.managedLocalModelStore = managedLocalModelStore
        self.allowsGlobalShortcutMonitoring = !isPreviewMode
            && ((loadSettingsFromDisk && engineOverride == nil) || shortcutMonitorOverride != nil)
        #if DEBUG
        pillBridge.isPreviewMode = isPreviewMode
        #endif
        pillBridge.onPresent = { [weak self] screen in self?.onPresentPill?(screen) }
        pillBridge.onUndo = { [weak self] in self?.undo() }
        pillBridge.onStateChange = { [weak self] state in self?.handleEngineState(state) }

        if accountClient != nil && engineOverride == nil {
            accountStatusRefreshTask = Task { [weak self] in await self?.refreshChatGPTAccount() }
        }
        if managedLocalModelStore != nil {
            Task { [weak self] in await self?.refreshManagedLocalModels() }
        }
        if allowsGlobalShortcutMonitoring { startShortcutMonitor() }
    }

    func invoke(presetID: String? = nil) {
        guard !isPreviewMode,
              !terminationRequested,
              !isRecordingShortcut,
              !isChangingManagedLocalModel,
              undoTask == nil
        else { return }
        pillBridge.invoke(presetID: presetID)
    }

    func beginShortcutRecording() -> UUID? {
        guard canChangeSettings, !terminationRequested, shortcutRecordingSessionID == nil else { return nil }
        let sessionID = UUID()
        shortcutRecordingSessionID = sessionID
        isRecordingShortcut = true
        stopShortcutMonitor()
        return sessionID
    }

    func retryKeyboardMonitoring() {
        requestShortcutMonitorRefreshIfInactive()
    }

    func applicationDidBecomeActive() {
        requestShortcutMonitorRefreshIfInactive()
    }

    func endShortcutRecording(_ sessionID: UUID) {
        guard shortcutRecordingSessionID == sessionID else { return }
        shortcutRecordingSessionID = nil
        isRecordingShortcut = false
        guard allowsGlobalShortcutMonitoring, !terminationRequested else {
            shortcutMonitorRefreshPending = false
            return
        }
        shortcutMonitorRefreshPending = true
        applyPendingRuntimeSettingsIfSafe()
    }

    func handleShortcutMonitorCallback(presetID: String?, activationEpoch: UInt64) {
        guard activationEpoch == shortcutMonitorActivationEpoch,
              !isRecordingShortcut, !terminationRequested, !isPreviewMode
        else { return }
        invoke(presetID: presetID)
    }

    func dismiss() {
        pillBridge.dismiss()
    }

    func escape() {
        dismiss()
    }

    func undo() {
        guard !isPreviewMode, !terminationRequested, canUndo else { return }
        pillModel.dismiss()
        undoTask = Task { [weak self] in
            guard let self else { return }
            await self.engine.undo()
            self.undoTask = nil
            if self.terminationRequested {
                self.finishTerminationIfSettled()
            } else {
                self.applyPendingRuntimeSettingsIfSafe()
            }
        }
    }

    @discardableResult
    func selectPillPreset(at index: Int) -> Bool {
        pillBridge.selectPreset(at: index)
    }

    #if DEBUG
    func presentPreviewState() {
        guard isPreviewMode else { return }
        guard let previewState else { return }
        pillModel.successDismissDelay = nil
        switch previewState {
        case .ready:
            pillModel.present()
            onPresentPill?(Self.screenUnderPointer())
        case .generating:
            pillModel.present()
            pillModel.submit()
            onPresentPill?(Self.screenUnderPointer())
        case .replacing:
            pillModel.present()
            pillModel.submit()
            if case .processing(let id) = pillModel.phase { pillModel.generated(id) }
            onPresentPill?(Self.screenUnderPointer())
        case .success:
            pillModel.present()
            pillModel.submit()
            if case .processing(let id) = pillModel.phase {
                pillModel.generated(id)
                pillModel.applied(id, undoAvailable: false)
            }
            onPresentPill?(Self.screenUnderPointer())
        case .error:
            pillModel.showCaptureFailure(message: ImrseError.network.message)
            onPresentPill?(Self.screenUnderPointer())
        case .hidden:
            break
        case .settings:
            break
        }
    }
    #endif

    func prepareForSettings() {
        guard canOpenSettings, !isPreviewMode else { return }
        dismiss()
    }

    func requestTermination(
        reply: @escaping @MainActor (NSApplication.TerminateReply) -> Void
    ) -> NSApplication.TerminateReply {
        terminationRequested = true
        isTerminating = true
        accountStatusRefreshTask?.cancel()
        accountStatusRefreshTask = nil
        cancelOfficialAccountStatusRefresh()
        cancelOfficialAccountSignIn()
        cancelChatGPTSignIn()
        let localModelOperationPending = managedLocalModelOperationTask != nil
        if managedLocalModelDownloadID != nil { managedLocalModelOperationTask?.cancel() }
        shortcutRecordingSessionID = nil
        isRecordingShortcut = false
        stopShortcutMonitor()
        pillBridge.dismiss()
        if undoTask != nil {
            terminationReplies.append(reply)
            return .terminateLater
        }
        switch engine.state {
        case .replacing, .undoing:
            terminationReplies.append(reply)
            return .terminateLater
        case .generating, .ready:
            engine.cancel()
            engine.dismiss()
        case .idle, .succeeded, .failed:
            engine.dismiss()
        }
        if localModelOperationPending {
            terminationReplies.append(reply)
            return .terminateLater
        }
        if !officialAccountOperationIDs.isEmpty || !officialAccountDeletionProviderIDs.isEmpty {
            terminationReplies.append(reply)
            return .terminateLater
        }
        return .terminateNow
    }

    func saveConfiguration(_ updated: AppConfiguration) throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        guard !updated.providers.contains(where: { officialAccountDeletionProviderIDs.contains($0.id) }) else {
            throw AppSettingsError.officialAccountOperationInProgress
        }
        if let activeProvider = officialAccountSignInProvider {
            guard let replacement = updated.providers.first(where: { $0.id == activeProvider.id }),
                  OfficialAccountProviderBinding(replacement) == OfficialAccountProviderBinding(activeProvider)
            else { throw AppSettingsError.officialAccountOperationInProgress }
        }
        try persistConfiguration(updated)
    }

    private func persistConfiguration(_ updated: AppConfiguration) throws {
        let previous = configuration
        try configurationStore.save(updated)
        configuration = updated
        if previous.clipboardFallbackEnabled != updated.clipboardFallbackEnabled {
            pendingClipboardFallback = updated.clipboardFallbackEnabled
        }
        if previous.invocation != updated.invocation { shortcutMonitorRefreshPending = true }
        pillBridge.update(configuration: configuration, defaultInstruction: defaultInstruction, presets: presets)
        applyPendingRuntimeSettingsIfSafe()
    }

    private func restoreAccountProviderAfterRemovalFailure(
        _ provider: ProviderConfiguration,
        wasSelectedProvider: Bool
    ) throws {
        try ensureWritableConfiguration()
        var updated = configuration
        if !updated.providers.contains(where: { $0.id == provider.id }) {
            updated.providers.append(provider)
        }
        if wasSelectedProvider, updated.selectedProviderID == nil {
            updated.selectedProviderID = provider.id
        }
        try persistConfiguration(updated)
    }

    func saveDefaultInstruction(_ instruction: String) throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        try configurationStore.saveDefaultInstruction(instruction)
        defaultInstruction = instruction
        pillBridge.update(configuration: configuration, defaultInstruction: defaultInstruction, presets: presets)
    }

    func saveProvider(_ provider: ProviderConfiguration) throws {
        guard !Self.isOfficialAccountProvider(provider.kind) || provider.model != Self.unselectedOfficialAccountModelID else {
            throw AppSettingsError.providerModelNotSelected
        }
        var updated = configuration
        let previous = updated.providers.first(where: { $0.id == provider.id })
        if let index = updated.providers.firstIndex(where: { $0.id == provider.id }) {
            updated.providers[index] = provider
        } else {
            updated.providers.append(provider)
        }
        updated.selectedProviderID = provider.id
        try saveConfiguration(updated)
        invalidateOfficialAccountStateIfBindingChanged(from: previous, to: provider)
    }

    func saveOfficialAccountRegistration(_ provider: ProviderConfiguration) throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        guard Self.isOfficialAccountProvider(provider.kind) else { throw ImrseError.invalidConfiguration }
        var updated = configuration
        let previous = updated.providers.first(where: { $0.id == provider.id })
        if let index = updated.providers.firstIndex(where: { $0.id == provider.id }) {
            updated.providers[index] = provider
        } else {
            updated.providers.append(provider)
        }
        try saveConfiguration(updated)
        invalidateOfficialAccountStateIfBindingChanged(from: previous, to: provider)
    }

    func officialAccountStatus(for provider: ProviderConfiguration) -> OfficialAccountConnectionStatus? {
        guard isCurrentOfficialAccountBinding(provider),
              officialAccountStatusBindings[provider.id] == OfficialAccountProviderBinding(provider)
        else { return nil }
        return officialAccountStatuses[provider.id]
    }

    func officialAccountModels(for provider: ProviderConfiguration) -> [OfficialAccountModel] {
        guard isCurrentOfficialAccountBinding(provider),
              officialAccountStatusBindings[provider.id] == OfficialAccountProviderBinding(provider)
        else { return [] }
        return officialAccountModels[provider.id] ?? []
    }

    func officialAccountIssue(for provider: ProviderConfiguration) -> String? {
        guard officialAccountStatusBindings[provider.id] == OfficialAccountProviderBinding(provider)
        else { return nil }
        return officialAccountIssues[provider.id]
    }

    func connectOfficialAccount(_ provider: ProviderConfiguration) {
        guard canChangeSettings,
              Self.isOfficialAccountProvider(provider.kind),
              !isConnectingOfficialAccount(for: provider.id),
              !isDisconnectingOfficialAccount(for: provider.id),
              !officialAccountDeletionProviderIDs.contains(provider.id),
              officialAccountSignInTask == nil,
              let officialAccountClient,
              let officialAccountSignInCoordinator
        else { return }

        do {
            try saveOfficialAccountRegistration(provider)
        } catch {
            officialAccountIssues[provider.id] = Self.userMessage(for: error)
            officialAccountStatusBindings[provider.id] = OfficialAccountProviderBinding(provider)
            return
        }

        cancelOfficialAccountStatusRefresh(for: provider.id)
        let sessionID = UUID()
        officialAccountSignInSessionID = sessionID
        officialAccountSigningInProviderID = provider.id
        officialAccountSignInProvider = provider
        officialAccountAttemptID = nil
        officialAccountDeviceCode = nil
        officialAccountDeviceVerificationURL = nil
        officialAccountDeviceCodeExpiresAt = nil
        officialAccountSignInCancellationRequestedProviderID = nil
        setOfficialAccountIssue(nil, for: provider)
        officialAccountOperationIDs.insert(sessionID)
        let signInTask = Task { [weak self] in
            var attemptID: UUID?
            defer { self?.finishOfficialAccountSignIn(sessionID: sessionID) }
            do {
                let redirectURI: URL?
                if provider.kind == .githubCopilot {
                    redirectURI = nil
                } else {
                    do {
                        redirectURI = try await officialAccountSignInCoordinator.prepareCallback()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw AppModelOfficialAccountSignInError.callbackUnavailable
                    }
                }
                try Task.checkCancellation()
                guard let self,
                      self.officialAccountSignInSessionID == sessionID,
                      self.isCurrentOfficialAccountBinding(provider),
                      !self.terminationRequested
                else {
                    return
                }
                let authorization = try await officialAccountClient.beginAuthorization(for: provider, redirectURI: redirectURI)
                switch authorization {
                case let .browser(authorizationURL, callbackURL, authorizationAttemptID):
                    attemptID = authorizationAttemptID
                    guard let redirectURI, callbackURL == redirectURI else {
                        throw OfficialAccountClientError.invalidCallback
                    }
                    try Task.checkCancellation()
                    guard self.officialAccountSignInSessionID == sessionID,
                          self.isCurrentOfficialAccountBinding(provider)
                    else {
                        await officialAccountClient.cancelAuthorizationAndWait(for: provider, attemptID: authorizationAttemptID)
                        return
                    }
                    self.officialAccountAttemptID = authorizationAttemptID
                    let callback: URL
                    do {
                        callback = try await officialAccountSignInCoordinator.openAndWait(
                            for: authorizationURL,
                            timeout: .seconds(180)
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw AppModelOfficialAccountSignInError.browserUnavailable
                    }
                    try Task.checkCancellation()
                    guard self.officialAccountSignInSessionID == sessionID,
                          self.isCurrentOfficialAccountBinding(provider)
                    else {
                        await officialAccountClient.cancelAuthorizationAndWait(for: provider, attemptID: authorizationAttemptID)
                        return
                    }
                    let status = try await officialAccountClient.completeAuthorization(for: provider, callbackURL: callback)
                    guard self.officialAccountSignInSessionID == sessionID,
                          self.isCurrentOfficialAccountBinding(provider),
                          !Task.isCancelled,
                          !self.terminationRequested
                    else {
                        await officialAccountClient.cancelAuthorizationAndWait(for: provider, attemptID: authorizationAttemptID)
                        return
                    }
                    self.setOfficialAccountStatus(status, for: provider)
                    if status.isConnected {
                        let models = try await officialAccountClient.availableModels(for: provider)
                        guard self.officialAccountSignInSessionID == sessionID,
                              self.isCurrentOfficialAccountBinding(provider),
                              !Task.isCancelled,
                              !self.terminationRequested
                        else { return }
                        self.officialAccountModels[provider.id] = models
                    } else {
                        self.officialAccountModels[provider.id] = []
                    }

                case let .deviceCode(userCode, verificationURL, expiresAt, authorizationAttemptID):
                    attemptID = authorizationAttemptID
                    guard provider.kind == .githubCopilot else { throw OfficialAccountClientError.unsupportedOperation }
                    try Task.checkCancellation()
                    guard self.officialAccountSignInSessionID == sessionID,
                          self.isCurrentOfficialAccountBinding(provider)
                    else {
                        await officialAccountClient.cancelAuthorizationAndWait(for: provider, attemptID: authorizationAttemptID)
                        return
                    }
                    self.officialAccountAttemptID = authorizationAttemptID
                    self.officialAccountDeviceCode = userCode
                    self.officialAccountDeviceVerificationURL = verificationURL
                    self.officialAccountDeviceCodeExpiresAt = expiresAt
                    guard officialAccountSignInCoordinator.openDeviceVerificationPage(for: verificationURL) else {
                        throw AppModelOfficialAccountSignInError.verificationPageUnavailable
                    }
                    let status = try await officialAccountClient.completeDeviceAuthorization(for: provider, attemptID: authorizationAttemptID)
                    guard self.officialAccountSignInSessionID == sessionID,
                          self.isCurrentOfficialAccountBinding(provider),
                          !Task.isCancelled,
                          !self.terminationRequested
                    else {
                        await officialAccountClient.cancelAuthorizationAndWait(for: provider, attemptID: authorizationAttemptID)
                        return
                    }
                    self.setOfficialAccountStatus(status, for: provider)
                    self.officialAccountModels[provider.id] = []
                }
                guard self.officialAccountSignInSessionID == sessionID,
                      self.isCurrentOfficialAccountBinding(provider),
                      !Task.isCancelled,
                      !self.terminationRequested
                else { return }
                self.setOfficialAccountIssue(nil, for: provider)
            } catch {
                guard let self,
                      self.officialAccountSignInSessionID == sessionID
                else {
                    if let attemptID {
                        await officialAccountClient.cancelAuthorizationAndWait(for: provider, attemptID: attemptID)
                    }
                    return
                }
                if !Task.isCancelled && !self.terminationRequested {
                    officialAccountSignInCoordinator.cancel()
                }
                if let attemptID {
                    await officialAccountClient.cancelAuthorizationAndWait(for: provider, attemptID: attemptID)
                }
                guard self.officialAccountSignInSessionID == sessionID else { return }
                if !Task.isCancelled,
                   !self.terminationRequested,
                   self.isCurrentOfficialAccountBinding(provider)
                {
                    self.setOfficialAccountIssue(Self.userMessage(for: error), for: provider)
                }
            }
        }
        officialAccountSignInTask = signInTask
    }

    func cancelOfficialAccountSignIn(for providerID: String? = nil) {
        guard let activeProvider = officialAccountSignInProvider,
              providerID == nil || activeProvider.id == providerID,
              let sessionID = officialAccountSignInSessionID,
              officialAccountSignInTask != nil
        else { return }
        guard officialAccountSignInSessionID == sessionID else { return }
        officialAccountSignInCancellationRequestedProviderID = activeProvider.id
        officialAccountSignInTask?.cancel()
        officialAccountSignInCoordinator?.cancel()
    }

    func disconnectOfficialAccount(for providerID: String) {
        guard canChangeSettings,
              !isConnectingOfficialAccount(for: providerID),
              !isDisconnectingOfficialAccount(for: providerID),
              !officialAccountDeletionProviderIDs.contains(providerID),
              let provider = configuration.providers.first(where: { $0.id == providerID && Self.isOfficialAccountProvider($0.kind) }),
              isCurrentOfficialAccountBinding(provider),
              let officialAccountClient
        else { return }
        cancelOfficialAccountStatusRefresh(for: providerID)
        officialAccountDisconnectingProviderIDs.insert(providerID)
        setOfficialAccountIssue(nil, for: provider)
        let operationID = UUID()
        officialAccountDisconnectTaskIDs[providerID] = operationID
        officialAccountOperationIDs.insert(operationID)
        let disconnectTask = Task { [weak self] in
            defer { self?.finishOfficialAccountDisconnect(providerID: providerID, operationID: operationID) }
            do {
                try await officialAccountClient.disconnect(for: provider)
                guard let self,
                      !self.terminationRequested,
                      self.isCurrentOfficialAccountBinding(provider)
                else { return }
                self.setOfficialAccountStatus(OfficialAccountConnectionStatus(isConnected: false, accountLabel: nil), for: provider)
                self.officialAccountModels[providerID] = []
                self.setOfficialAccountIssue(nil, for: provider)
            } catch {
                guard let self,
                      !self.terminationRequested,
                      self.isCurrentOfficialAccountBinding(provider)
                else { return }
                self.setOfficialAccountIssue(Self.userMessage(for: error), for: provider)
            }
        }
        officialAccountDisconnectTasks[providerID] = disconnectTask
    }

    func refreshOfficialAccount(for provider: ProviderConfiguration) {
        guard canChangeSettings,
              Self.isOfficialAccountProvider(provider.kind),
              !isConnectingOfficialAccount(for: provider.id),
              !isDisconnectingOfficialAccount(for: provider.id),
              !officialAccountDeletionProviderIDs.contains(provider.id),
              isCurrentOfficialAccountBinding(provider),
              let officialAccountClient
        else { return }
        let requiresClientID = provider.kind == .huggingFaceAccount || provider.kind == .githubCopilot
        guard !requiresClientID || !(provider.oauthClientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            cancelOfficialAccountStatusRefresh(for: provider.id)
            setOfficialAccountStatus(OfficialAccountConnectionStatus(isConnected: false, accountLabel: nil), for: provider)
            officialAccountModels[provider.id] = []
            setOfficialAccountIssue(nil, for: provider)
            return
        }
        cancelOfficialAccountStatusRefresh()
        let sessionID = UUID()
        officialAccountStatusRefreshSessionID = sessionID
        officialAccountStatusRefreshTaskID = sessionID
        officialAccountRefreshingProviderID = provider.id
        setOfficialAccountIssue(nil, for: provider)
        officialAccountOperationIDs.insert(sessionID)
        let refreshTask = Task { [weak self] in
            defer { self?.finishOfficialAccountStatusRefresh(sessionID: sessionID) }
            do {
                let status = try await officialAccountClient.connectionStatus(for: provider)
                guard let self,
                      self.officialAccountStatusRefreshSessionID == sessionID,
                      !Task.isCancelled,
                      !self.terminationRequested,
                      self.isCurrentOfficialAccountBinding(provider)
                else { return }
                self.setOfficialAccountStatus(status, for: provider)
                if status.isConnected {
                    if provider.kind == .githubCopilot {
                        self.officialAccountModels[provider.id] = []
                    } else {
                        let models = try await officialAccountClient.availableModels(for: provider)
                        guard self.officialAccountStatusRefreshSessionID == sessionID,
                              !Task.isCancelled,
                              !self.terminationRequested,
                              self.isCurrentOfficialAccountBinding(provider)
                        else { return }
                        self.officialAccountModels[provider.id] = models
                    }
                } else {
                    self.officialAccountModels[provider.id] = []
                }
                guard self.officialAccountStatusRefreshSessionID == sessionID,
                      !Task.isCancelled,
                      !self.terminationRequested,
                      self.isCurrentOfficialAccountBinding(provider)
                else { return }
            } catch {
                guard let self,
                      self.officialAccountStatusRefreshSessionID == sessionID,
                      !Task.isCancelled,
                      !self.terminationRequested,
                      self.isCurrentOfficialAccountBinding(provider)
                else { return }
                self.setOfficialAccountIssue(Self.userMessage(for: error), for: provider)
            }
        }
        officialAccountStatusRefreshTask = refreshTask
    }

    func cancelOfficialAccountStatusRefresh(for providerID: String? = nil) {
        guard officialAccountRefreshingProviderID != nil,
              providerID == nil || officialAccountRefreshingProviderID == providerID
        else { return }
        officialAccountStatusRefreshSessionID = nil
        officialAccountRefreshingProviderID = nil
        officialAccountStatusRefreshTask?.cancel()
    }

    func isConnectingOfficialAccount(for providerID: String) -> Bool {
        officialAccountSigningInProviderID == providerID
    }

    func isDisconnectingOfficialAccount(for providerID: String) -> Bool {
        officialAccountDisconnectingProviderIDs.contains(providerID)
    }

    private func finishOfficialAccountSignIn(sessionID: UUID) {
        if officialAccountSignInSessionID == sessionID {
            officialAccountSignInSessionID = nil
            officialAccountSigningInProviderID = nil
            officialAccountSignInProvider = nil
            officialAccountAttemptID = nil
            officialAccountDeviceCode = nil
            officialAccountDeviceVerificationURL = nil
            officialAccountDeviceCodeExpiresAt = nil
            officialAccountSignInCancellationRequestedProviderID = nil
            officialAccountSignInTask = nil
        }
        finishOfficialAccountOperation(sessionID)
    }

    private func finishOfficialAccountStatusRefresh(sessionID: UUID) {
        if officialAccountStatusRefreshSessionID == sessionID {
            officialAccountStatusRefreshSessionID = nil
            officialAccountRefreshingProviderID = nil
        }
        if officialAccountStatusRefreshTaskID == sessionID {
            officialAccountStatusRefreshTaskID = nil
            officialAccountStatusRefreshTask = nil
        }
        finishOfficialAccountOperation(sessionID)
    }

    private func finishOfficialAccountDisconnect(providerID: String, operationID: UUID) {
        if officialAccountDisconnectTaskIDs[providerID] == operationID {
            officialAccountDisconnectTaskIDs[providerID] = nil
            officialAccountDisconnectingProviderIDs.remove(providerID)
            officialAccountDisconnectTasks[providerID] = nil
        }
        finishOfficialAccountOperation(operationID)
    }

    private func finishOfficialAccountOperation(_ operationID: UUID) {
        officialAccountOperationIDs.remove(operationID)
        finishTerminationIfSettled()
    }

    var copilotRuntimeIsAvailable: Bool { copilotRuntime != nil }

    func saveCredential(_ credential: String, for providerID: String) async throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        try await credentialStore.setCredential(credential, for: providerID)
    }

    func deleteProvider(id: String) async throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        guard !presets.contains(where: { $0.providerID == id || $0.fallbackProviderID == id }) else {
            throw AppSettingsError.providerInUse
        }
        let isAccountProvider = configuration.providers.contains { $0.id == id && $0.kind == .openAIChatGPT }
        if isAccountProvider {
            guard id == connectedChatGPTProviderID,
                  !isConnectingChatGPT, !isDisconnectingChatGPT,
                  let openAIAccountClient
            else { throw OpenAIAccountClientError.invalidConfiguration }
            isDisconnectingChatGPT = true
            defer { isDisconnectingChatGPT = false }
            accountStatusRefreshTask?.cancel()
            accountStatusRefreshTask = nil
            accountStatusSessionID = UUID()
            isRefreshingChatGPTAccount = false
            chatGPTStatus = nil
            chatGPTModels = []
            chatGPTIssue = nil
            do {
                try await openAIAccountClient.disconnect(for: id)
                try Task.checkCancellation()
                try ensureSettingsCanChange()
                guard !presets.contains(where: { $0.providerID == id || $0.fallbackProviderID == id }) else {
                    throw AppSettingsError.providerInUse
                }
                var updated = configuration
                updated.providers.removeAll { $0.id == id }
                if updated.selectedProviderID == id { updated.selectedProviderID = nil }
                try saveConfiguration(updated)
                chatGPTStatus = OpenAIAccountStatus(isConnected: false, canUseChatGPTPlan: false, accountLabel: nil)
            } catch {
                chatGPTIssue = Self.userMessage(for: error)
                throw error
            }
            return
        }
        if let provider = configuration.providers.first(where: { $0.id == id && Self.isOfficialAccountProvider($0.kind) }) {
            guard !isConnectingOfficialAccount(for: id),
                  !isDisconnectingOfficialAccount(for: id),
                  !officialAccountDeletionProviderIDs.contains(id),
                  let officialAccountClient
            else { throw OfficialAccountClientError.invalidConfiguration }
            cancelOfficialAccountStatusRefresh(for: id)
            let wasSelectedProvider = configuration.selectedProviderID == id
            var updated = configuration
            updated.providers.removeAll { $0.id == id }
            if wasSelectedProvider { updated.selectedProviderID = nil }
            let operationID = UUID()
            officialAccountDeletionProviderIDs.insert(id)
            officialAccountOperationIDs.insert(operationID)
            defer {
                officialAccountDeletionProviderIDs.remove(id)
                finishOfficialAccountOperation(operationID)
            }
            try saveConfiguration(updated)
            do {
                try await officialAccountClient.disconnect(for: provider)
                clearOfficialAccountState(for: id)
            } catch {
                let removalError = error
                do {
                    try restoreAccountProviderAfterRemovalFailure(
                        provider,
                        wasSelectedProvider: wasSelectedProvider
                    )
                    clearOfficialAccountState(for: id)
                    setOfficialAccountIssue(Self.userMessage(for: removalError), for: provider)
                } catch let rollbackError {
                    configurationIssue = Self.userMessage(for: rollbackError)
                }
                throw removalError
            }
            return
        }
        var updated = configuration
        updated.providers.removeAll { $0.id == id }
        if updated.selectedProviderID == id { updated.selectedProviderID = nil }
        try saveConfiguration(updated)
        try await credentialStore.setCredential(nil, for: id)
    }

    func hasCredential(for providerID: String) async throws -> Bool {
        try ensureSettingsCanChange()
        guard configuration.providers.contains(where: { $0.id == providerID }) else { return false }
        return try await credentialStore.credential(for: providerID) != nil
    }

    func providerReasoningEffortCapabilities(for provider: ProviderConfiguration) async throws -> ReasoningEffortCapabilities? {
        try ensureSettingsCanChange()
        let isPublicOpenRouterCatalog = provider.kind == .openRouter
            && URLComponents(url: provider.endpoint, resolvingAgainstBaseURL: false)?.host?.lowercased() == "openrouter.ai"
        if provider.requiresCredential && !isPublicOpenRouterCatalog {
            let savedDestinationMatches = configuration.providers.contains { savedProvider in
                savedProvider.id == provider.id
                    && savedProvider.endpoint == provider.endpoint
                    && savedProvider.kind == provider.kind
                    && savedProvider.requiresCredential == provider.requiresCredential
            }
            guard savedDestinationMatches else {
                throw AppModelProviderModelCatalogError.unsavedAuthenticatedDestination
            }
        }
        let capabilities = try await providerModelCatalogClient.reasoningEffortCapabilities(for: provider)
        try Task.checkCancellation()
        try ensureSettingsCanChange()
        return capabilities
    }

    func removeCredential(for providerID: String) async throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        try await credentialStore.setCredential(nil, for: providerID)
    }

    func refreshChatGPTAccount() async {
        guard !isPreviewMode, !terminationRequested, !isDisconnectingChatGPT, let openAIAccountClient else { return }
        let sessionID = UUID()
        accountStatusSessionID = sessionID
        isRefreshingChatGPTAccount = true
        chatGPTIssue = nil
        defer {
            if accountStatusSessionID == sessionID { isRefreshingChatGPTAccount = false }
        }
        do {
            let status = try await openAIAccountClient.connectionStatus(for: connectedChatGPTProviderID)
            guard accountStatusSessionID == sessionID, !Task.isCancelled, !terminationRequested else { return }
            chatGPTStatus = status
            guard status.isConnected, status.canUseChatGPTPlan else {
                chatGPTModels = []
                return
            }
            let models = try await openAIAccountClient.availableModels(for: connectedChatGPTProviderID)
            guard accountStatusSessionID == sessionID, !Task.isCancelled, !terminationRequested else { return }
            chatGPTModels = models
        } catch {
            guard accountStatusSessionID == sessionID, !Task.isCancelled, !terminationRequested else { return }
            chatGPTIssue = Self.userMessage(for: error)
            chatGPTModels = []
        }
    }

    func connectChatGPTAccount() {
        guard canChangeSettings,
              !isConnectingChatGPT,
              !isDisconnectingChatGPT,
              let openAIAccountClient,
              let chatGPTSignInCoordinator
        else { return }
        let sessionID = UUID()
        accountStatusRefreshTask?.cancel()
        accountStatusRefreshTask = nil
        accountStatusSessionID = sessionID
        chatGPTSignInSessionID = sessionID
        chatGPTAccountAttemptID = nil
        isRefreshingChatGPTAccount = false
        isConnectingChatGPT = true
        chatGPTIssue = nil
        let providerID = connectedChatGPTProviderID
        chatGPTSignInTask = Task { [weak self] in
            var accountAttemptID: UUID?
            do {
                let redirectURI = try await chatGPTSignInCoordinator.prepareCallback()
                try Task.checkCancellation()
                guard self?.chatGPTSignInSessionID == sessionID else { return }
                let request = try await openAIAccountClient.prepareSignIn(
                    for: providerID,
                    redirectURI: redirectURI
                )
                accountAttemptID = request.attemptID
                try Task.checkCancellation()
                guard self?.chatGPTSignInSessionID == sessionID else {
                    await openAIAccountClient.cancelSignIn(for: providerID, attemptID: request.attemptID)
                    return
                }
                self?.chatGPTAccountAttemptID = request.attemptID
                let callbackURL = try await chatGPTSignInCoordinator.openAndWait(
                    for: request.authorizationURL,
                    timeout: .seconds(180)
                )
                try Task.checkCancellation()
                guard self?.chatGPTSignInSessionID == sessionID else {
                    await openAIAccountClient.cancelSignIn(for: providerID, attemptID: request.attemptID)
                    return
                }
                let status = try await openAIAccountClient.completeSignIn(for: providerID, callbackURL: callbackURL)
                guard let self,
                      self.chatGPTSignInSessionID == sessionID,
                      !Task.isCancelled,
                      !self.terminationRequested
                else { return }
                self.chatGPTStatus = status
                let models = status.isConnected && status.canUseChatGPTPlan
                    ? try await openAIAccountClient.availableModels(for: providerID)
                    : []
                guard self.chatGPTSignInSessionID == sessionID, !Task.isCancelled, !self.terminationRequested else { return }
                self.chatGPTModels = models
                self.chatGPTIssue = nil
            } catch {
                if let accountAttemptID {
                    await openAIAccountClient.cancelSignIn(for: providerID, attemptID: accountAttemptID)
                }
                guard let self, self.chatGPTSignInSessionID == sessionID, !self.terminationRequested else { return }
                if !Task.isCancelled { self.chatGPTIssue = Self.userMessage(for: error) }
            }
            guard let self, self.chatGPTSignInSessionID == sessionID else { return }
            self.chatGPTSignInSessionID = nil
            self.chatGPTAccountAttemptID = nil
            self.chatGPTSignInTask = nil
            self.isConnectingChatGPT = false
        }
    }

    func cancelChatGPTSignIn() {
        guard chatGPTSignInSessionID != nil else { return }
        let accountAttemptID = chatGPTAccountAttemptID
        chatGPTSignInSessionID = nil
        chatGPTAccountAttemptID = nil
        chatGPTSignInTask?.cancel()
        chatGPTSignInTask = nil
        chatGPTSignInCoordinator?.cancel()
        isRefreshingChatGPTAccount = false
        isConnectingChatGPT = false
        guard let openAIAccountClient, let accountAttemptID else { return }
        let providerID = connectedChatGPTProviderID
        Task { await openAIAccountClient.cancelSignIn(for: providerID, attemptID: accountAttemptID) }
    }

    func disconnectChatGPTAccount() {
        guard canChangeSettings,
              !isConnectingChatGPT,
              !isDisconnectingChatGPT,
              let openAIAccountClient
        else { return }
        accountStatusRefreshTask?.cancel()
        accountStatusRefreshTask = nil
        isDisconnectingChatGPT = true
        let sessionID = UUID()
        let providerID = connectedChatGPTProviderID
        accountStatusSessionID = sessionID
        isRefreshingChatGPTAccount = false
        chatGPTIssue = nil
        Task { [weak self] in
            do {
                try await openAIAccountClient.disconnect(for: providerID)
                guard let self, self.accountStatusSessionID == sessionID, !self.terminationRequested else { return }
                let status = try await openAIAccountClient.connectionStatus(for: providerID)
                guard self.accountStatusSessionID == sessionID, !self.terminationRequested else { return }
                self.chatGPTStatus = status
                self.chatGPTModels = []
                self.chatGPTIssue = nil
            } catch {
                guard let self, self.accountStatusSessionID == sessionID, !self.terminationRequested else { return }
                if (error as? OpenAIAccountClientError) == .revocationUnconfirmed {
                    let status = try? await openAIAccountClient.connectionStatus(for: providerID)
                    guard self.accountStatusSessionID == sessionID, !self.terminationRequested else { return }
                    self.chatGPTStatus = status
                    self.chatGPTModels = []
                }
                self.chatGPTIssue = Self.userMessage(for: error)
            }
            guard let self, self.accountStatusSessionID == sessionID else { return }
            self.isDisconnectingChatGPT = false
        }
    }

    func refreshManagedLocalModels() async {
        guard !isPreviewMode, !terminationRequested, let managedLocalModelStore else { return }
        let snapshots = await managedLocalModelStore.snapshots()
        guard !Task.isCancelled, !terminationRequested else { return }
        managedLocalModelSnapshots = snapshots
    }

    func managedLocalModelIsInUse(_ modelID: String) -> Bool {
        presets.contains { preset in
            if let providerID = preset.providerID,
               let provider = configuration.providers.first(where: { $0.id == providerID && $0.kind == .managedLocal }),
               (preset.model ?? provider.model) == modelID
            {
                return true
            }
            if let providerID = preset.fallbackProviderID,
               let provider = configuration.providers.first(where: { $0.id == providerID && $0.kind == .managedLocal }),
               provider.model == modelID
            {
                return true
            }
            return false
        }
    }

    func downloadManagedModel(_ modelID: String) {
        runManagedLocalModelInstall(modelID, action: .download)
    }

    func repairManagedModel(_ modelID: String) {
        runManagedLocalModelInstall(modelID, action: .repair)
    }

    private func runManagedLocalModelInstall(_ modelID: String, action: ManagedLocalModelInstallAction) {
        guard canChangeSettings,
              !isChangingManagedLocalModel,
              ManagedLocalModelCatalog.runtimeAvailability == .available,
              ManagedLocalModelCatalog.model(id: modelID) != nil,
              let store = managedLocalModelStore
        else { return }
        if case .repair = action {
            guard managedLocalModelSnapshots.contains(where: { snapshot in
                guard snapshot.descriptor.id == modelID else { return false }
                if case .installed = snapshot.state { return true }
                return false
            }) else { return }
        }
        let sessionID = UUID()
        managedLocalModelOperationSessionID = sessionID
        managedLocalModelDownloadID = modelID
        managedLocalModelProgress = nil
        managedLocalModelIssue = nil
        isChangingManagedLocalModel = true
        let progressThrottle = ManagedLocalProgressThrottle()
        let publishProgress: @Sendable (ManagedLocalModelProgress) -> Void = { [weak self] progress in
            guard progressThrottle.shouldPublish() else { return }
            Task { @MainActor [weak self] in
                guard let self, self.managedLocalModelOperationSessionID == sessionID else { return }
                self.managedLocalModelProgress = progress
            }
        }
        managedLocalModelOperationTask = Task { [weak self] in
            var operationError: Error?
            do {
                switch action {
                case .download:
                    try await store.download(modelID: modelID, progress: publishProgress)
                case .repair:
                    try await store.repair(modelID: modelID, progress: publishProgress)
                }
            } catch is CancellationError {
            } catch {
                operationError = error
            }
            guard let self, self.managedLocalModelOperationSessionID == sessionID else { return }
            self.managedLocalModelSnapshots = await store.snapshots()
            guard self.managedLocalModelOperationSessionID == sessionID else { return }
            self.managedLocalModelIssue = operationError.map { Self.userMessage(for: $0) }
            self.finishManagedLocalModelOperation(sessionID: sessionID)
        }
    }

    func cancelManagedModelDownload(_ modelID: String) {
        guard managedLocalModelDownloadID == modelID, !isTerminating else { return }
        managedLocalModelOperationTask?.cancel()
    }

    func removeManagedModel(_ modelID: String) {
        guard canChangeSettings,
              !isChangingManagedLocalModel,
              !managedLocalModelIsInUse(modelID),
              let store = managedLocalModelStore
        else { return }
        let sessionID = UUID()
        managedLocalModelOperationSessionID = sessionID
        managedLocalModelProgress = nil
        managedLocalModelIssue = nil
        isChangingManagedLocalModel = true
        managedLocalModelOperationTask = Task { [weak self] in
            var operationError: Error?
            do {
                try await store.remove(modelID: modelID)
            } catch {
                operationError = error
            }
            guard let self, self.managedLocalModelOperationSessionID == sessionID else { return }
            self.managedLocalModelSnapshots = await store.snapshots()
            guard self.managedLocalModelOperationSessionID == sessionID else { return }
            self.managedLocalModelIssue = operationError.map { Self.userMessage(for: $0) }
            self.finishManagedLocalModelOperation(sessionID: sessionID)
        }
    }

    func savePreset(_ preset: Preset) throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        try configurationStore.savePreset(preset)
        presets = try configurationStore.loadPresets()
        pillBridge.update(configuration: configuration, defaultInstruction: defaultInstruction, presets: presets)
        shortcutMonitorRefreshPending = true
        applyPendingRuntimeSettingsIfSafe()
    }

    func deletePreset(id: String) throws {
        try ensureWritableConfiguration()
        try ensureSettingsCanChange()
        try configurationStore.deletePreset(id: id)
        presets = try configurationStore.loadPresets()
        pillBridge.update(configuration: configuration, defaultInstruction: defaultInstruction, presets: presets)
        shortcutMonitorRefreshPending = true
        applyPendingRuntimeSettingsIfSafe()
    }

    var redactedDiagnosticsReport: String {
        var metadata = engine.diagnostics
        if !isPreviewMode {
            metadata.accessibilityGranted = MacSelectionAccess.accessibilityPermissionGranted
            metadata.eventMonitoringActive = shortcutMonitor.isMonitoring
        }
        return DiagnosticReport.render(metadata)
    }

    func copyDiagnostics() -> Bool {
        guard !isPreviewMode else { return false }
        let report = redactedDiagnosticsReport
        let pasteboard = NSPasteboard.general
        _ = pasteboard.clearContents()
        let copied = pasteboard.setString(report, forType: .string)
        diagnosticsCopiedMessage = copied ? "Redacted diagnostics copied" : "Couldn't copy diagnostics"
        return copied
    }

    func revealConfigurationFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.applicationSupportURL])
    }

    func reloadConfiguration() -> String? {
        do {
            try ensureSettingsCanChange()
            let loadedConfiguration = try configurationStore.load()
            let loadedInstruction = try configurationStore.loadDefaultInstruction()
            let loadedPresets = try configurationStore.loadPresets()
            let previousConfiguration = configuration
            let previousPresets = presets
            configuration = loadedConfiguration
            defaultInstruction = loadedInstruction
            presets = loadedPresets
            configurationIssue = nil
            if previousConfiguration.clipboardFallbackEnabled != loadedConfiguration.clipboardFallbackEnabled {
                pendingClipboardFallback = loadedConfiguration.clipboardFallbackEnabled
            }
            if previousConfiguration.invocation != loadedConfiguration.invocation || previousPresets != loadedPresets {
                shortcutMonitorRefreshPending = true
            }
            pillBridge.update(configuration: configuration, defaultInstruction: defaultInstruction, presets: presets)
            applyPendingRuntimeSettingsIfSafe()
            return nil
        } catch {
            let message = Self.userMessage(for: error)
            configurationIssue = message
            return message
        }
    }

    static func userMessage(for error: Error) -> String {
        if let error = error as? ImrseError { return error.message }
        if let error = error as? LocalizedError, let message = error.errorDescription { return message }
        if let error = error as? ManagedLocalModelStoreError {
            switch error {
            case .unknownModel, .missingModel:
                return "This local model is no longer available."
            case .busy:
                return "Another local model operation is still running."
            case .alreadyInstalled:
                return "This local model is already downloaded."
            case .invalidManifest, .invalidInstalledModel, .integrityMismatch:
                return "This local model couldn't be verified."
            case .unsafeRedirect:
                return "The model download was redirected to an unsafe location."
            case .downloadFailed:
                return "Couldn't download this local model. Check your connection."
            }
        }
        if let error = error as? KeychainCredentialStoreError {
            switch error {
            case .invalidItemIdentifier:
                return "A provider ID is required to store a Keychain key."
            case .invalidCredentialData:
                return "The saved Keychain item can't be read. Remove it and enter the key again."
            case .operationFailed(let operation, _):
                return "Keychain couldn't \(operation) this credential."
            }
        }
        if let error = error as? AppSettingsError {
            switch error {
            case .transformationInProgress:
                return "Finish the current transformation before changing settings."
            case .terminationInProgress:
                return "Settings aren't available while imrse is quitting."
            case .providerInUse:
                return "Edit presets that use this provider before removing it."
            case .providerModelNotSelected:
                return "Choose a model ID before saving this account as the default."
            case .officialAccountOperationInProgress:
                return "Wait for account sign-in or removal to finish before changing its registration."
            #if DEBUG
            case .previewMode:
                return "Settings are read-only in preview mode."
            #endif
            }
        }
        return "Couldn't save these settings. Check the values and try again."
    }

    private static var applicationSupportURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("imrse", isDirectory: true)
    }

    private func ensureWritableConfiguration() throws {
        guard configurationIssue == nil else { throw ImrseError.invalidConfiguration }
    }

    private func ensureSettingsCanChange() throws {
        #if DEBUG
        guard !isPreviewMode else { throw AppSettingsError.previewMode }
        #endif
        guard !terminationRequested else { throw AppSettingsError.terminationInProgress }
        guard !isProcessing else { throw AppSettingsError.transformationInProgress }
    }

    static func uniqueProviderID(candidate: String, existingProviders: [ProviderConfiguration]) -> String {
        var identifier = candidate
        var suffix = 2
        while existingProviders.contains(where: { $0.id == identifier }) {
            identifier = "\(candidate)-\(suffix)"
            suffix += 1
        }
        return identifier
    }

    private static func isOfficialAccountProvider(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .openRouterAccount, .huggingFaceAccount, .githubCopilot: true
        default: false
        }
    }

    private func isCurrentOfficialAccountBinding(_ provider: ProviderConfiguration) -> Bool {
        guard Self.isOfficialAccountProvider(provider.kind),
              let current = configuration.providers.first(where: { $0.id == provider.id })
        else { return false }
        return OfficialAccountProviderBinding(current) == OfficialAccountProviderBinding(provider)
    }

    private func invalidateOfficialAccountStateIfBindingChanged(
        from previous: ProviderConfiguration?,
        to provider: ProviderConfiguration
    ) {
        guard Self.isOfficialAccountProvider(provider.kind) else { return }
        let previousBinding = previous.map(OfficialAccountProviderBinding.init)
        let nextBinding = OfficialAccountProviderBinding(provider)
        guard previousBinding != nextBinding
                || (previous == nil && officialAccountStatusBindings[provider.id] != nextBinding)
        else { return }
        cancelOfficialAccountStatusRefresh(for: provider.id)
        cancelOfficialAccountSignIn(for: provider.id)
        clearOfficialAccountState(for: provider.id)
    }

    private func clearOfficialAccountState(for providerID: String) {
        officialAccountStatuses[providerID] = nil
        officialAccountModels[providerID] = nil
        officialAccountIssues[providerID] = nil
        officialAccountStatusBindings[providerID] = nil
    }

    private func setOfficialAccountStatus(
        _ status: OfficialAccountConnectionStatus,
        for provider: ProviderConfiguration
    ) {
        guard isCurrentOfficialAccountBinding(provider) else { return }
        officialAccountStatuses[provider.id] = status
        officialAccountStatusBindings[provider.id] = OfficialAccountProviderBinding(provider)
    }

    private func setOfficialAccountIssue(_ issue: String?, for provider: ProviderConfiguration) {
        guard isCurrentOfficialAccountBinding(provider) else { return }
        officialAccountIssues[provider.id] = issue
        officialAccountStatusBindings[provider.id] = OfficialAccountProviderBinding(provider)
    }

    private static func copilotRuntimeExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/copilot"),
            URL(fileURLWithPath: "/usr/local/bin/copilot"),
            home.appendingPathComponent(".local/bin/copilot"),
            home.appendingPathComponent(".npm-global/bin/copilot"),
            home.appendingPathComponent(".volta/bin/copilot"),
            home.appendingPathComponent(".bun/bin/copilot"),
            home.appendingPathComponent(".local/share/mise/shims/copilot")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func handleEngineState(_ state: TransformationState) {
        switch state {
        case .ready, .generating:
            latestResponseMetadata = nil
        case .succeeded(_), .failed(_):
            if self.state != .undoing {
                latestResponseMetadata = engine.responseMetadata
            }
        case .idle, .replacing, .undoing:
            break
        }
        if self.state != state { logLifecycleChange(state) }
        self.state = state
        if terminationRequested {
            finishTerminationIfSettled()
            return
        }
        applyPendingRuntimeSettingsIfSafe()
    }

    private func logLifecycleChange(_ state: TransformationState) {
        if case .generating = state { lifecycleStartedAt = Date() }
        if case .undoing = state { lifecycleStartedAt = Date() }

        let stateName = Self.lifecycleStateName(state)
        let errorCategory: String
        if case .failed(let error) = state {
            errorCategory = error.rawValue
        } else {
            errorCategory = "none"
        }
        let durationMilliseconds = lifecycleStartedAt.map {
            String(Int(max(0, Date().timeIntervalSince($0)) * 1_000))
        } ?? "none"
        let strategy = engine.diagnostics.strategy?.rawValue ?? "none"
        let provider = lifecycleProviderLabel
        lifecycleLogger.info(
            "state=\(stateName, privacy: .public) error_category=\(errorCategory, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) strategy=\(strategy, privacy: .public) provider=\(provider, privacy: .public)"
        )

        if case .succeeded = state { lifecycleStartedAt = nil }
        if case .failed = state { lifecycleStartedAt = nil }
    }

    private var lifecycleProviderLabel: String {
        let selectedPreset = pillModel.selectedPresetID.flatMap { selectedID in
            presets.first { $0.id == selectedID }
        }
        let providerID = selectedPreset?.providerID ?? configuration.selectedProviderID
        guard let providerID,
              let provider = configuration.providers.first(where: { $0.id == providerID })
        else { return "unresolved" }
        return "\(provider.name) · \(selectedPreset?.model ?? provider.model)"
    }

    private static func lifecycleStateName(_ state: TransformationState) -> String {
        return switch state {
        case .idle: "idle"
        case .ready: "ready"
        case .generating: "generating"
        case .replacing: "replacing"
        case .undoing: "undoing"
        case .succeeded(let unchanged): unchanged ? "succeeded-unchanged" : "succeeded-replaced"
        case .failed: "failed"
        }
    }

    private static func screenUnderPointer() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    private func startShortcutMonitor() {
        guard allowsGlobalShortcutMonitoring,
              !isRecordingShortcut,
              !terminationRequested,
              !isTerminating,
              !isPreviewMode,
              !isProcessing
        else { return }
        stopShortcutMonitor()
        guard configurationIssue == nil else {
            shortcutIssue = configurationIssue
            return
        }
        let activationEpoch = shortcutMonitorActivationEpoch
        do {
            try shortcutMonitor.start(configuration: configuration.invocation, presets: presets) { [weak self] presetID in
                self?.handleShortcutMonitorCallback(presetID: presetID, activationEpoch: activationEpoch)
            }
            shortcutIssue = nil
        } catch let error as ShortcutMonitorError {
            shortcutIssue = error.errorDescription ?? "Keyboard monitoring couldn't start."
        } catch let error as ImrseError where error == .shortcutConflict {
            shortcutIssue = error.message
        } catch {
            shortcutIssue = "Keyboard monitoring couldn't start. Check Input Monitoring in System Settings, then retry."
        }
    }

    private func requestShortcutMonitorRefreshIfInactive() {
        guard allowsGlobalShortcutMonitoring,
              !isPreviewMode,
              !terminationRequested,
              !isTerminating,
              !shortcutMonitor.isMonitoring
        else { return }
        shortcutMonitorRefreshPending = true
        applyPendingRuntimeSettingsIfSafe()
    }

    private func applyPendingRuntimeSettingsIfSafe() {
        guard !isProcessing, !terminationRequested, !isTerminating, !isPreviewMode, !isRecordingShortcut else { return }
        if let pendingClipboardFallback {
            selectionAccess.clipboardFallbackEnabled = pendingClipboardFallback
            self.pendingClipboardFallback = nil
        }
        if shortcutMonitorRefreshPending {
            shortcutMonitorRefreshPending = false
            startShortcutMonitor()
        }
    }

    private func stopShortcutMonitor() {
        shortcutMonitorActivationEpoch &+= 1
        shortcutMonitor.stop()
    }

    private func finishManagedLocalModelOperation(sessionID: UUID) {
        guard managedLocalModelOperationSessionID == sessionID else { return }
        managedLocalModelOperationSessionID = nil
        managedLocalModelOperationTask = nil
        managedLocalModelDownloadID = nil
        managedLocalModelProgress = nil
        isChangingManagedLocalModel = false
        finishTerminationIfSettled()
    }

    private func finishTerminationIfSettled() {
        guard !terminationReplies.isEmpty,
              undoTask == nil,
              managedLocalModelOperationTask == nil,
              officialAccountOperationIDs.isEmpty,
              officialAccountDeletionProviderIDs.isEmpty,
              state != .replacing,
              state != .undoing
        else { return }
        let replies = terminationReplies
        terminationReplies = []
        engine.dismiss()
        replies.forEach { $0(.terminateNow) }
    }

    #if DEBUG
    var hasAccountRuntime: Bool { openAIAccountClient != nil }
    var hasOfficialAccountClient: Bool { officialAccountClient != nil }
    var hasManagedLocalModelStore: Bool { managedLocalModelStore != nil }
    var hasPendingOfficialAccountOperationsForTesting: Bool { !officialAccountOperationIDs.isEmpty }
    var chatGPTSignInTaskForTesting: Task<Void, Never>? { chatGPTSignInTask }

    private static let previewConfiguration = AppConfiguration(
        providers: [
            ProviderConfiguration(
                id: "preview-provider",
                name: "Preview provider",
                kind: .compatible,
                endpoint: URL(string: "https://example.invalid/v1") ?? URL(fileURLWithPath: "/"),
                model: "preview-model",
                requiresCredential: false
            )
        ],
        selectedProviderID: "preview-provider"
    )

    private static let previewPresets = [
        Preset(
            id: "preview-preset",
            name: "Preview preset",
            instruction: "Preview only; no provider is called.",
            providerID: "preview-provider"
        )
    ]
    #endif

    static let defaultChatGPTProviderID = "imrse-chatgpt"
    static let unselectedOfficialAccountModelID = "__select_model__"
}

private enum AppSettingsError: Error {
    case transformationInProgress
    case terminationInProgress
    case providerInUse
    case providerModelNotSelected
    case officialAccountOperationInProgress
    #if DEBUG
    case previewMode
    #endif
}

private enum AppModelOfficialAccountSignInError: Error, LocalizedError {
    case callbackUnavailable
    case browserUnavailable
    case verificationPageUnavailable

    var errorDescription: String? {
        switch self {
        case .callbackUnavailable: "The local sign-in callback couldn't start. Try again."
        case .browserUnavailable: "The browser sign-in didn't finish. Return to imrse and try again."
        case .verificationPageUnavailable: "The GitHub device-verification page couldn't be opened. Try again."
        }
    }
}

private final class ManagedLocalProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate: UInt64 = 0

    func shouldPublish() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard now - lastUpdate >= 100_000_000 else { return false }
        lastUpdate = now
        return true
    }
}
#endif
