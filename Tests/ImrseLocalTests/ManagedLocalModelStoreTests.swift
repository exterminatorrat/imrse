import CryptoKit
import Foundation
import ImrseCore
import XCTest
@testable import ImrseLocal

final class ManagedLocalModelStoreTests: XCTestCase {
    func testDownloadVerifiesEveryArtifactBeforeAtomicInstall() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Data("config-1".utf8)
        let expectedWeights = Data("weights-1".utf8)
        let wrongWeights = Data("weights-2".utf8)
        let manifest = fixtureManifest([
            artifact("config.json", first),
            artifact("model.safetensors", expectedWeights)
        ])
        let store = ManagedLocalModelStore(root: root, manifests: [manifest]) { source, destination, _, progress in
            let data = source.lastPathComponent == "config.json" ? first : wrongWeights
            try data.write(to: destination)
            progress(Int64(data.count))
        }

        do {
            try await store.download(modelID: manifest.descriptor.id)
            XCTFail("A mismatched artifact hash must fail the install")
        } catch let error as ManagedLocalModelStoreError {
            XCTAssertEqual(error, .integrityMismatch)
        }

        let modelDirectory = root.appendingPathComponent("models/test-model", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        let snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.first?.state, .notInstalled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path), [])
    }

    func testIncompleteOrWrongRevisionInstallIsNotReadyAndCanBeRepaired() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let store = makeStore(root: root, manifest: manifest, contents: contents)
        let modelDirectory = root.appendingPathComponent("models/test-model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try contents.write(to: modelDirectory.appendingPathComponent("config.json"))

        var snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.first?.state, .notInstalled)

        let incorrectReceipt: [String: Any] = [
            "schemaVersion": 1,
            "modelID": manifest.descriptor.id,
            "revision": String(repeating: "0", count: 40),
            "artifacts": [[
                "path": "config.json",
                "byteCount": contents.count,
                "sha256": artifact("config.json", contents).sha256
            ]]
        ]
        let receiptData = try JSONSerialization.data(withJSONObject: incorrectReceipt)
        try receiptData.write(to: modelDirectory.appendingPathComponent(".imrse-install.json"))
        snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.first?.state, .notInstalled)

        try await store.download(modelID: manifest.descriptor.id)

        snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.first?.state, .installed)
        let provider = ManagedLocalTextProvider(store: store) { _, _, _, _ in generatedText("repaired") }
        let output = try await collect(provider, request(modelID: manifest.descriptor.id))
        XCTAssertEqual(output, "repaired")
    }

    func testDownloadCancellationRemovesThePartialStagingDirectory() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let started = TestSignal()
        let store = ManagedLocalModelStore(root: root, manifests: [manifest]) { _, destination, _, progress in
            try contents.write(to: destination)
            progress(Int64(contents.count))
            await started.signal()
            try await Task.sleep(for: .seconds(60))
        }
        let download = Task { try await store.download(modelID: manifest.descriptor.id) }
        await started.wait()
        let downloadingSnapshots = await store.snapshots()
        if case .some(.downloading(_)) = downloadingSnapshots.first?.state {
        } else {
            XCTFail("The model should remain in downloading state until installation finishes")
        }
        download.cancel()

        do {
            try await download.value
            XCTFail("Cancellation must stop the install")
        } catch is CancellationError {
        }

        let snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.first?.state, .notInstalled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path), [])
    }

    func testGenerationReservesModelAgainstRemovalAndConcurrentUse() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let store = makeStore(root: root, manifest: manifest, contents: contents)
        try await store.download(modelID: manifest.descriptor.id)

        let generationStarted = TestSignal()
        let provider = ManagedLocalTextProvider(store: store) { _, _, _, _ in
            await generationStarted.signal()
            try await Task.sleep(for: .seconds(60))
            return generatedText("finished")
        }
        let generation = Task { try await collect(provider, request(modelID: manifest.descriptor.id)) }
        await generationStarted.wait()
        let generationIsActive = await store.isInUse(manifest.descriptor.id)
        XCTAssertTrue(generationIsActive)

        do {
            try await store.remove(modelID: manifest.descriptor.id)
            XCTFail("An active model must not be removable")
        } catch let error as ManagedLocalModelStoreError {
            XCTAssertEqual(error, .busy)
        }

        let secondProvider = ManagedLocalTextProvider(store: store) { _, _, _, _ in generatedText("unused") }
        await assertError(.localModelUnavailable) {
            _ = try await collect(secondProvider, request(modelID: manifest.descriptor.id))
        }
        generation.cancel()
        do {
            let output = try await generation.value
            XCTAssertTrue(output.isEmpty, "A cancelled consumer must not receive partial output")
        } catch is CancellationError {
        } catch let error as ImrseError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        for _ in 0..<100 {
            if !(await store.isInUse(manifest.descriptor.id)) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let generationRemainsActive = await store.isInUse(manifest.descriptor.id)
        XCTAssertFalse(generationRemainsActive)
    }

    func testProviderPassesHardThinkingOffContextAndReturnsOnlyTransformedText() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let store = makeStore(root: root, manifest: manifest, contents: contents)
        try await store.download(modelID: manifest.descriptor.id)
        let recorder = ThinkingContextRecorder()
        let provider = ManagedLocalTextProvider(store: store) { _, instructions, prompt, context in
            await recorder.record(instructions: instructions, prompt: prompt, context: context)
            return generatedText("the quick brown fox.")
        }

        let output = try await collect(provider, request(modelID: manifest.descriptor.id))

        XCTAssertEqual(output, "the quick brown fox.")
        let recorded = await recorder.snapshot()
        XCTAssertEqual(recorded.prompt, "teh quick brown fox.")
        XCTAssertTrue(recorded.instructions.contains("Return only the transformed text"))
        XCTAssertEqual(recorded.context["enable_thinking"] as? Bool, false)
    }

    func testNormalTextStreamAtTokenBudgetStillFailsClosed() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let store = makeStore(root: root, manifest: manifest, contents: contents)
        try await store.download(modelID: manifest.descriptor.id)

        let provider = ManagedLocalTextProvider(store: store) { _, _, _, _ in
            generatedText("truncated transformation", tokenCount: 2_048, termination: .stop)
        }

        await assertError(.malformedResponse) {
            _ = try await collect(provider, request(modelID: manifest.descriptor.id))
        }
    }

    func testLengthCancellationAndMissingCompletionAreRejected() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let store = makeStore(root: root, manifest: manifest, contents: contents)
        try await store.download(modelID: manifest.descriptor.id)
        let request = request(modelID: manifest.descriptor.id)

        let lengthProvider = ManagedLocalTextProvider(store: store) { _, _, _, _ in
            generatedText("truncated", tokenCount: 2_048, termination: .length)
        }
        await assertError(.malformedResponse) {
            _ = try await collect(lengthProvider, request)
        }

        let cancellationProvider = ManagedLocalTextProvider(store: store) { _, _, _, _ in
            generatedText("partial", tokenCount: 12, termination: .cancelled)
        }
        await assertError(.cancelled) {
            _ = try await collect(cancellationProvider, request)
        }

        let incompleteProvider = ManagedLocalTextProvider(store: store) { _, _, _, _ in
            generatedText("partial", tokenCount: 12, termination: .incomplete)
        }
        await assertError(.malformedResponse) {
            _ = try await collect(incompleteProvider, request)
        }
    }

    func testPreparedPromptTokenLimitRejectsBeforeGeneration() throws {
        XCTAssertNoThrow(try ManagedLocalGenerationLimits.validatePreparedPromptTokenCount(8_192))
        XCTAssertThrowsError(try ManagedLocalGenerationLimits.validatePreparedPromptTokenCount(8_193)) { error in
            XCTAssertEqual(error as? ImrseError, .selectionTooLarge)
        }
    }

    func testReasoningMarkupFailsClosedWithoutReturningAnyOutput() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let store = makeStore(root: root, manifest: manifest, contents: contents)
        try await store.download(modelID: manifest.descriptor.id)
        let provider = ManagedLocalTextProvider(store: store) { _, _, _, _ in
            generatedText("rewritten text <think>private reasoning</think>")
        }

        await assertError(.malformedResponse) {
            _ = try await collect(provider, request(modelID: manifest.descriptor.id))
        }
    }

    func testCorruptInstalledArtifactCannotBeLoaded() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let store = makeStore(root: root, manifest: manifest, contents: contents)
        try await store.download(modelID: manifest.descriptor.id)
        let installedFile = root.appendingPathComponent("models/test-model/config.json")
        try Data("tampered!".utf8).write(to: installedFile)
        let snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.first?.state, .notInstalled)
        let provider = ManagedLocalTextProvider(store: store) { _, _, _, _ in generatedText("must not run") }

        await assertError(.localModelUnavailable) {
            _ = try await collect(provider, request(modelID: manifest.descriptor.id))
        }
    }

    func testSameSizeCorruptionCanBeExplicitlyRepaired() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let manifest = fixtureManifest([artifact("config.json", contents)])
        let transfers = TransferCounter()
        let store = ManagedLocalModelStore(root: root, manifests: [manifest]) { _, destination, _, progress in
            await transfers.increment()
            try contents.write(to: destination)
            progress(Int64(contents.count))
        }
        let modelFile = root.appendingPathComponent("models/test-model/config.json")
        try await store.download(modelID: manifest.descriptor.id)
        try await store.repair(modelID: manifest.descriptor.id)
        var transferCount = await transfers.value()
        XCTAssertEqual(transferCount, 1)

        let corrupted = Data("tampered".utf8)
        XCTAssertEqual(corrupted.count, contents.count)
        try corrupted.write(to: modelFile)
        let snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.first?.state, .installed)

        let provider = ManagedLocalTextProvider(store: store) { _, _, _, _ in generatedText("repaired") }
        await assertError(.localModelUnavailable) {
            _ = try await collect(provider, request(modelID: manifest.descriptor.id))
        }

        try await store.repair(modelID: manifest.descriptor.id)
        transferCount = await transfers.value()
        XCTAssertEqual(transferCount, 2)
        XCTAssertEqual(try Data(contentsOf: modelFile), contents)
        let output = try await collect(provider, request(modelID: manifest.descriptor.id))
        XCTAssertEqual(output, "repaired")
    }

    func testUnsafePathsAndRedirectDestinationsAreRejected() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = Data("verified".utf8)
        let invalid = fixtureManifest([artifact("../outside", contents)])
        let store = makeStore(root: root, manifest: invalid, contents: contents)

        do {
            try await store.download(modelID: invalid.descriptor.id)
            XCTFail("Artifact paths must remain inside app-owned staging")
        } catch let error as ManagedLocalModelStoreError {
            XCTAssertEqual(error, .invalidManifest)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(ManagedLocalModelStore.isAllowedDownloadURL(URL(string: "https://cdn-lfs.huggingface.co/model")!))
        XCTAssertFalse(ManagedLocalModelStore.isAllowedDownloadURL(URL(string: "http://huggingface.co/model")!))
        XCTAssertFalse(ManagedLocalModelStore.isAllowedDownloadURL(URL(string: "https://huggingface.co.attacker.example/model")!))
    }

    func testStoreInitializationDoesNotCreateItsRoot() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedLocalModelStore(root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.count, ManagedLocalModelCatalog.models.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

private actor TestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor TransferCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor ThinkingContextRecorder {
    private var instructions = ""
    private var prompt = ""
    private var context: [String: any Sendable] = [:]

    func record(instructions: String, prompt: String, context: [String: any Sendable]) {
        self.instructions = instructions
        self.prompt = prompt
        self.context = context
    }

    func snapshot() -> (instructions: String, prompt: String, context: [String: any Sendable]) {
        (instructions, prompt, context)
    }
}

private func testRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("imrse-local-test-\(UUID().uuidString)", isDirectory: true)
}

private func artifact(_ path: String, _ contents: Data) -> ManagedLocalModelArtifact {
    let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
    return ManagedLocalModelArtifact(path: path, byteCount: Int64(contents.count), sha256: digest)
}

private func fixtureManifest(_ artifacts: [ManagedLocalModelArtifact]) -> ManagedLocalModelManifest {
    let original = ManagedLocalModelCatalog.models[0]
    let descriptor = ManagedLocalModelDescriptor(
        id: original.id,
        title: original.title,
        detail: original.detail,
        revision: original.revision,
        license: original.license,
        downloadBytes: artifacts.reduce(0) { $0 + $1.byteCount },
        minimumMemoryBytes: nil
    )
    return ManagedLocalModelManifest(descriptor: descriptor, storageName: "test-model", artifacts: artifacts)
}

private func makeStore(root: URL, manifest: ManagedLocalModelManifest, contents: Data) -> ManagedLocalModelStore {
    ManagedLocalModelStore(root: root, manifests: [manifest]) { _, destination, _, progress in
        try contents.write(to: destination)
        progress(Int64(contents.count))
    }
}

private func generatedText(
    _ text: String,
    tokenCount: Int = 1,
    termination: ManagedLocalGenerationTermination = .stop
) -> ManagedLocalGenerationResult {
    ManagedLocalGenerationResult(text: text, generationTokenCount: tokenCount, termination: termination)
}

private func request(modelID: String) -> TransformationRequest {
    TransformationRequest(
        text: "teh quick brown fox.",
        instruction: "Fix spelling only.",
        provider: ProviderConfiguration(
            id: "local",
            name: "Local",
            kind: .managedLocal,
            endpoint: URL(string: "imrse-local://models")!,
            model: modelID,
            requiresCredential: false
        ),
        localOnly: true
    )
}

private func collect(_ provider: ManagedLocalTextProvider, _ request: TransformationRequest) async throws -> String {
    let stream = try await provider.stream(request)
    var result = ""
    for try await chunk in stream { result += chunk }
    return result
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
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}
