import Foundation
import ImrseCore
import ImrsePillUI
import ImrseServices
import Testing
@testable import ImrseApp

@Suite("Configured provider direct Apply regressions")
@MainActor
struct ConfiguredProviderApplyTests {
    @Test(
        "Direct Apply sends selected text and instruction to the configured route, then undoes its exact snapshot",
        .timeLimit(.minutes(1))
    )
    func selectedTextUsesConfiguredRouteAndBoundUndo() async throws {
        let selection = SyntheticSelectionAccess()
        let provider = compatibleProvider(
            id: "selected-provider",
            endpoint: "https://selected.example.test/custom/v1",
            model: "selected-model"
        )
        let decoy = compatibleProvider(
            id: "decoy-provider",
            endpoint: "https://decoy.example.test/v1",
            model: "decoy-model"
        )
        let transport = SyntheticHTTPTransport(mode: .immediate(fragments: ["A revised ", "selection."]))
        let bridge = makeBridge(
            selection: selection,
            textProvider: configuredProvider(transport: transport),
            configuration: AppConfiguration(providers: [provider, decoy], selectedProviderID: provider.id)
        )
        bridge.onUndo = { [weak bridge] in
            guard let bridge else { return }
            Task { await bridge.engine.undo() }
        }
        let events = observeStates(from: bridge)
        defer { events.continuation.finish() }

        bridge.invoke()
        bridge.pill.instruction = "Keep the meaning and improve clarity"
        bridge.pill.submit()

        let applyState = try await terminalState(from: events.stream)
        try #require(applyState == .succeeded(unchanged: false))
        let capturedRequest = try await transport.waitForFirstRequest()
        let request = try #require(capturedRequest)
        try expectRequest(
            request,
            endpoint: "https://selected.example.test/custom/v1/chat/completions",
            model: "selected-model",
            selectedText: selection.snapshot.text,
            instruction: "Keep the meaning and improve clarity",
            credential: "synthetic-selected-provider-token"
        )
        try await transport.waitForExchangeClosure()

        #expect(selection.captureCount == 1)
        #expect(selection.validatedTargets == [selection.snapshot])
        #expect(selection.writes == [
            SyntheticSelectionAccess.Write(target: selection.snapshot, replacement: "A revised selection.")
        ])
        #expect(selection.currentSelectionText == "A revised selection.")
        #expect(bridge.engine.canUndo)
        #expect(bridge.pill.canUndo)

        let undoEvents = observeStates(from: bridge)
        defer { undoEvents.continuation.finish() }
        bridge.pill.undo()

        let undoState = try await terminalState(from: undoEvents.stream)
        try #require(undoState == .succeeded(unchanged: false))
        #expect(selection.undoReceipts == [
            ReplacementReceipt(target: selection.snapshot, replacement: "A revised selection.", strategy: .selectedText)
        ])
        #expect(selection.currentSelectionText == selection.snapshot.text)
        #expect(!bridge.engine.canUndo)
    }

    @Test("A preset override uses its configured provider endpoint and model", .timeLimit(.minutes(1)))
    func presetUsesConfiguredOverrideRouteAndModel() async throws {
        let selection = SyntheticSelectionAccess()
        let selected = compatibleProvider(
            id: "selected-provider",
            endpoint: "https://selected.example.test/v1",
            model: "selected-model"
        )
        let presetProvider = compatibleProvider(
            id: "preset-provider",
            endpoint: "https://preset.example.test/openai/v1",
            model: "configured-base-model"
        )
        let preset = Preset(
            id: "profile",
            name: "Profile",
            instruction: "Make this concise",
            providerID: presetProvider.id,
            model: "profile-model"
        )
        let transport = SyntheticHTTPTransport(mode: .immediate(fragments: ["Concise result."]))
        let bridge = makeBridge(
            selection: selection,
            textProvider: configuredProvider(transport: transport),
            configuration: AppConfiguration(providers: [selected, presetProvider], selectedProviderID: selected.id),
            presets: [preset]
        )
        let events = observeStates(from: bridge)
        defer { events.continuation.finish() }

        bridge.invoke(presetID: preset.id)

        let terminal = try await terminalState(from: events.stream)
        try #require(terminal == .succeeded(unchanged: false))
        let capturedRequest = try await transport.waitForFirstRequest()
        let request = try #require(capturedRequest)
        try expectRequest(
            request,
            endpoint: "https://preset.example.test/openai/v1/chat/completions",
            model: "profile-model",
            selectedText: selection.snapshot.text,
            instruction: preset.instruction,
            credential: "synthetic-preset-provider-token"
        )
        try await transport.waitForExchangeClosure()
        #expect(selection.writes.map(\.replacement) == ["Concise result."])
    }

    @Test("A stale original selection is not replaced after a streamed response", .timeLimit(.minutes(1)))
    func staleSnapshotIsNotApplied() async throws {
        let selection = SyntheticSelectionAccess()
        let provider = compatibleProvider(
            id: "stale-provider",
            endpoint: "https://stale.example.test/v1",
            model: "stale-model"
        )
        let transport = SyntheticHTTPTransport(mode: .held)
        defer { Task { await transport.releasePendingResponse() } }
        let bridge = makeBridge(
            selection: selection,
            textProvider: configuredProvider(transport: transport),
            configuration: AppConfiguration(providers: [provider], selectedProviderID: provider.id)
        )
        let events = observeStates(from: bridge)
        defer { events.continuation.finish() }

        bridge.invoke()
        bridge.pill.submit()
        let request = try await transport.waitForFirstRequest()
        _ = try #require(request)
        selection.isStale = true
        try await transport.respond(with: ["Must not replace the stale selection."])

        let terminal = try await terminalState(from: events.stream)
        try #require(terminal == .failed(.staleSelection))
        try await transport.waitForExchangeClosure()
        #expect(selection.validatedTargets == [selection.snapshot])
        #expect(selection.writes.isEmpty)
        #expect(!bridge.engine.canUndo)
    }

    @Test("Cancellation ignores a provider response released after the pill is dismissed", .timeLimit(.minutes(1)))
    func cancellationIgnoresLateProviderCompletion() async throws {
        let selection = SyntheticSelectionAccess()
        let provider = compatibleProvider(
            id: "cancel-provider",
            endpoint: "https://cancel.example.test/v1",
            model: "cancel-model"
        )
        let transport = SyntheticHTTPTransport(mode: .held)
        defer { Task { await transport.releasePendingResponse() } }
        let bridge = makeBridge(
            selection: selection,
            textProvider: configuredProvider(transport: transport),
            configuration: AppConfiguration(providers: [provider], selectedProviderID: provider.id)
        )
        let events = observeStates(from: bridge)
        defer { events.continuation.finish() }

        bridge.invoke()
        bridge.pill.submit()
        let request = try await transport.waitForFirstRequest()
        _ = try #require(request)
        bridge.pill.dismiss()

        let terminal = try await terminalState(from: events.stream)
        try #require(terminal == .failed(.cancelled))
        try await transport.respond(with: ["Late provider result."])
        try await transport.waitForExchangeClosure()

        #expect(bridge.engine.state == .failed(.cancelled))
        #expect(selection.writes.isEmpty)
        #expect(selection.undoReceipts.isEmpty)
    }
}

@MainActor
private func makeBridge(
    selection: SyntheticSelectionAccess,
    textProvider: any TextProvider,
    configuration: AppConfiguration,
    presets: [Preset] = []
) -> AppPillBridge {
    let pill = PillModel(onSubmit: { _ in })
    pill.successDismissDelay = nil
    let engine = TransformationEngine(selectionAccess: selection, textProvider: textProvider)
    return AppPillBridge(
        engine: engine,
        pill: pill,
        configuration: configuration,
        defaultInstruction: "Use the default instruction",
        presets: presets,
        screenAfterCapture: { nil },
        fallbackScreen: { nil }
    )
}

private func configuredProvider(transport: any StreamingHTTPTransport) -> RoutedTextProvider {
    let credentials = SyntheticCredentialStore()
    let compatible = OpenAICompatibleProvider(credentials: credentials, transport: transport)
    let dispatch = ProviderDispatchProvider(compatible: compatible)
    return RoutedTextProvider(primary: dispatch)
}

private func compatibleProvider(id: String, endpoint: String, model: String) -> ProviderConfiguration {
    ProviderConfiguration(
        id: id,
        name: id,
        kind: .compatible,
        endpoint: URL(string: endpoint)!,
        model: model
    )
}

private struct StateEvents {
    let stream: AsyncStream<TransformationState>
    let continuation: AsyncStream<TransformationState>.Continuation
}

@MainActor
private func observeStates(from bridge: AppPillBridge) -> StateEvents {
    let pair = AsyncStream<TransformationState>.makeStream()
    bridge.onStateChange = { state in pair.continuation.yield(state) }
    return StateEvents(stream: pair.stream, continuation: pair.continuation)
}

private func terminalState(from states: AsyncStream<TransformationState>) async throws -> TransformationState? {
    for await state in states {
        try Task.checkCancellation()
        switch state {
        case .succeeded, .failed:
            return state
        case .idle, .ready, .generating, .replacing, .undoing:
            continue
        }
    }
    try Task.checkCancellation()
    return nil
}

private func expectRequest(
    _ request: CapturedHTTPRequest,
    endpoint: String,
    model: String,
    selectedText: String,
    instruction: String,
    credential: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(request.url == endpoint, sourceLocation: sourceLocation)
    #expect(request.method == "POST", sourceLocation: sourceLocation)
    #expect(request.authorization == "Bearer \(credential)", sourceLocation: sourceLocation)
    #expect(!request.localOnly, sourceLocation: sourceLocation)

    let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any], sourceLocation: sourceLocation)
    let messages = try #require(body["messages"] as? [[String: Any]], sourceLocation: sourceLocation)
    try #require(messages.count == 2, sourceLocation: sourceLocation)
    let system = try #require(messages.first, sourceLocation: sourceLocation)
    let user = try #require(messages.last, sourceLocation: sourceLocation)
    #expect(body["model"] as? String == model, sourceLocation: sourceLocation)
    #expect(body["stream"] as? Bool == true, sourceLocation: sourceLocation)
    #expect(system["role"] as? String == "system", sourceLocation: sourceLocation)
    #expect(system["content"] as? String == instruction, sourceLocation: sourceLocation)
    #expect(user["role"] as? String == "user", sourceLocation: sourceLocation)
    #expect(user["content"] as? String == selectedText, sourceLocation: sourceLocation)
}

@MainActor
private final class SyntheticSelectionAccess: SelectionAccess {
    struct Write: Equatable {
        let target: SelectionSnapshot
        let replacement: String
    }

    let snapshot: SelectionSnapshot
    var isStale = false
    private(set) var currentSelectionText: String
    private(set) var captureCount = 0
    private(set) var validatedTargets: [SelectionSnapshot] = []
    private(set) var writes: [Write] = []
    private(set) var undoReceipts: [ReplacementReceipt] = []

    init() {
        let text = "the exact selected words"
        snapshot = SelectionSnapshot(
            applicationID: "test.editor",
            processID: 42,
            role: "text field",
            text: text,
            range: ImrseCore.TextRange(location: 31, length: text.utf16.count)
        )
        currentSelectionText = text
    }

    func capture() throws -> SelectionSnapshot {
        captureCount += 1
        return snapshot
    }

    func validate(_ target: SelectionSnapshot) throws {
        validatedTargets.append(target)
        guard !isStale, target == snapshot else { throw ImrseError.staleSelection }
    }

    func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        writes.append(Write(target: target, replacement: text))
        currentSelectionText = text
        return ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
    }

    func undo(_ receipt: ReplacementReceipt) async throws {
        undoReceipts.append(receipt)
        currentSelectionText = receipt.target.text
    }

    func discard(_ target: SelectionSnapshot) {}
}

private actor SyntheticCredentialStore: CredentialStore {
    func credential(for providerID: String) async throws -> String? {
        "synthetic-\(providerID)-token"
    }

    func setCredential(_ value: String?, for providerID: String) async throws {}
}

private struct CapturedHTTPRequest: Sendable {
    let url: String
    let method: String
    let authorization: String
    let body: Data
    let localOnly: Bool
}

private actor SyntheticHTTPTransport: StreamingHTTPTransport {
    enum Mode: Sendable {
        case immediate(fragments: [String])
        case held
    }

    private let mode: Mode
    private var requests: [CapturedHTTPRequest] = []
    private let requestEvents: AsyncStream<CapturedHTTPRequest>
    private let requestContinuation: AsyncStream<CapturedHTTPRequest>.Continuation
    private var pendingResponse: CheckedContinuation<HTTPExchange, any Error>?
    private let exchangeClosureEvents: AsyncStream<Void>
    private let exchangeClosureContinuation: AsyncStream<Void>.Continuation

    init(mode: Mode) {
        self.mode = mode
        let requests = AsyncStream<CapturedHTTPRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requestEvents = requests.stream
        requestContinuation = requests.continuation
        let closures = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        exchangeClosureEvents = closures.stream
        exchangeClosureContinuation = closures.continuation
    }

    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        let captured = CapturedHTTPRequest(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization") ?? "",
            body: request.httpBody ?? Data(),
            localOnly: localOnly
        )
        requests.append(captured)
        if requests.count == 1 {
            requestContinuation.yield(captured)
            requestContinuation.finish()
        }

        switch mode {
        case .immediate(let fragments):
            return try makeExchange(fragments: fragments)
        case .held:
            return try await withCheckedThrowingContinuation { pendingResponse = $0 }
        }
    }

    func waitForFirstRequest() async throws -> CapturedHTTPRequest? {
        if let request = requests.first { return request }
        for await request in requestEvents {
            try Task.checkCancellation()
            return request
        }
        try Task.checkCancellation()
        return nil
    }

    func respond(with fragments: [String]) throws {
        guard let pendingResponse else { throw SyntheticTransportError.noPendingResponse }
        self.pendingResponse = nil
        pendingResponse.resume(returning: try makeExchange(fragments: fragments))
    }

    func releasePendingResponse() {
        guard let pendingResponse else { return }
        self.pendingResponse = nil
        pendingResponse.resume(throwing: CancellationError())
    }

    func waitForExchangeClosure() async throws {
        for await _ in exchangeClosureEvents {
            try Task.checkCancellation()
            return
        }
        try Task.checkCancellation()
    }

    private func makeExchange(fragments: [String]) throws -> HTTPExchange {
        let chunks = try fragments.map { fragment in try Self.sseChunk(fragment) }
            + [Data("data: [DONE]\n\n".utf8)]
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return HTTPExchange(statusCode: 200, headers: ["content-type": "text/event-stream"], body: body) {
            Task { await self.recordExchangeClosure() }
        }
    }

    private func recordExchangeClosure() {
        exchangeClosureContinuation.yield(())
        exchangeClosureContinuation.finish()
    }

    private static func sseChunk(_ fragment: String) throws -> Data {
        let event = try JSONSerialization.data(withJSONObject: [
            "choices": [["delta": ["content": fragment], "finish_reason": NSNull()]]
        ])
        return Data("data: \(String(decoding: event, as: UTF8.self))\n\n".utf8)
    }
}

private enum SyntheticTransportError: Error {
    case noPendingResponse
}
