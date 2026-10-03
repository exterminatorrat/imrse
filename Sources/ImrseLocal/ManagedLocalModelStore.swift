import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ManagedLocalModelStoreError: Error, Equatable, Sendable {
    case unknownModel
    case busy
    case alreadyInstalled
    case missingModel
    case invalidManifest
    case invalidInstalledModel
    case integrityMismatch
    case unsafeRedirect
    case downloadFailed
}

private struct ManagedLocalInstallReceipt: Codable, Equatable {
    struct Artifact: Codable, Equatable {
        let path: String
        let byteCount: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let modelID: String
    let revision: String
    let artifacts: [Artifact]

    init(manifest: ManagedLocalModelManifest) {
        schemaVersion = 1
        modelID = manifest.descriptor.id
        revision = manifest.descriptor.revision
        artifacts = manifest.artifacts.map {
            Artifact(path: $0.path, byteCount: $0.byteCount, sha256: $0.sha256)
        }
    }
}

public struct ManagedLocalModelProgress: Equatable, Sendable {
    public let modelID: String
    public let completedBytes: Int64
    public let totalBytes: Int64
}

typealias ManagedLocalArtifactTransfer = @Sendable (
    URL, URL, Int64, @escaping @Sendable (Int64) -> Void
) async throws -> Void

public actor ManagedLocalModelStore {
    private static let installReceiptName = ".imrse-install.json"

    private enum ActiveOperation: Equatable {
        case download(String, Int64)
        case generation(String)
    }

    private let root: URL
    private let manifests: [ManagedLocalModelManifest]
    private let transfer: ManagedLocalArtifactTransfer
    private var activeOperation: ActiveOperation?

    public init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imrse/LocalModels", isDirectory: true)
        manifests = ManagedLocalModelCatalog.manifests
        transfer = Self.transferArtifact
    }

    init(root: URL) {
        self.root = root.standardizedFileURL
        manifests = ManagedLocalModelCatalog.manifests
        transfer = Self.transferArtifact
    }

    init(root: URL, manifests: [ManagedLocalModelManifest], transfer: @escaping ManagedLocalArtifactTransfer) {
        self.root = root.standardizedFileURL
        self.manifests = manifests
        self.transfer = transfer
    }

    public func snapshots() -> [ManagedLocalModelSnapshot] {
        manifests.map { manifest in
            let state: ManagedLocalModelSnapshot.State
            if case .download(let modelID, let completedBytes) = activeOperation,
               modelID == manifest.descriptor.id
            {
                state = .downloading(completedBytes)
            } else if Self.isCompleteInstall(manifest, at: modelDirectory(for: manifest)) {
                state = .installed
            } else {
                state = .notInstalled
            }
            return ManagedLocalModelSnapshot(descriptor: manifest.descriptor, state: state)
        }
    }

    public func isInUse(_ modelID: String) -> Bool {
        if case .generation(let activeID) = activeOperation { return activeID == modelID }
        return false
    }

    public func download(
        modelID: String,
        progress: @escaping @Sendable (ManagedLocalModelProgress) -> Void = { _ in }
    ) async throws {
        guard let manifest = manifest(for: modelID) else { throw ManagedLocalModelStoreError.unknownModel }
        guard activeOperation == nil else { throw ManagedLocalModelStoreError.busy }
        try Self.validate(manifest)
        if try Self.isVerifiedInstall(manifest, at: modelDirectory(for: manifest)) {
            throw ManagedLocalModelStoreError.alreadyInstalled
        }

        let operationID = UUID()
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(operationID.uuidString, isDirectory: true)
        activeOperation = .download(modelID, 0)
        currentOperationID = operationID
        defer {
            activeOperation = nil
            currentOperationID = nil
            try? FileManager.default.removeItem(at: staging)
        }

        do {
            try Self.ensureDirectory(root)
            try Self.ensureDirectory(root.appendingPathComponent(".staging", isDirectory: true))
            try Self.ensureDirectory(staging)

            var completedBytes: Int64 = 0
            for artifact in manifest.artifacts {
                try Task.checkCancellation()
                let destination = try Self.artifactURL(artifact.path, under: staging)
                try Self.ensureDirectory(destination.deletingLastPathComponent())
                let source = try Self.sourceURL(for: manifest, artifact: artifact)
                let baseBytes = completedBytes
                let report: @Sendable (Int64) -> Void = { [weak self] receivedBytes in
                    progress(.init(
                        modelID: modelID,
                        completedBytes: baseBytes + receivedBytes,
                        totalBytes: manifest.descriptor.downloadBytes
                    ))
                    Task { await self?.updateProgress(modelID: modelID, operationID: operationID, completedBytes: baseBytes + receivedBytes) }
                }
                try await transfer(source, destination, artifact.byteCount, report)
                try Task.checkCancellation()
                try Self.verify(artifact, at: destination)
                completedBytes += artifact.byteCount
            }

            try Task.checkCancellation()
            let receipt = try JSONEncoder().encode(ManagedLocalInstallReceipt(manifest: manifest))
            try receipt.write(
                to: staging.appendingPathComponent(Self.installReceiptName),
                options: .atomic
            )
            let modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
            try Self.ensureDirectory(modelsDirectory)
            let destination = modelDirectory(for: manifest)
            if Self.itemExists(destination) {
                if try Self.isVerifiedInstall(manifest, at: destination) {
                    throw ManagedLocalModelStoreError.alreadyInstalled
                }
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    throw ManagedLocalModelStoreError.invalidInstalledModel
                }
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ManagedLocalModelStoreError {
            throw error
        } catch {
            throw ManagedLocalModelStoreError.downloadFailed
        }
    }

    public func repair(
        modelID: String,
        progress: @escaping @Sendable (ManagedLocalModelProgress) -> Void = { _ in }
    ) async throws {
        do {
            try await download(modelID: modelID, progress: progress)
        } catch ManagedLocalModelStoreError.alreadyInstalled {
            return
        }
    }

    public func remove(modelID: String) throws {
        guard let manifest = manifest(for: modelID) else { throw ManagedLocalModelStoreError.unknownModel }
        guard activeOperation == nil else { throw ManagedLocalModelStoreError.busy }
        let directory = modelDirectory(for: manifest)
        guard Self.isDirectory(directory) else { throw ManagedLocalModelStoreError.missingModel }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw ManagedLocalModelStoreError.invalidInstalledModel
        }
    }

    func withInstalledModel<T: Sendable>(
        modelID: String,
        operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        guard let manifest = manifest(for: modelID) else { throw ManagedLocalModelStoreError.unknownModel }
        guard activeOperation == nil else { throw ManagedLocalModelStoreError.busy }
        let directory = modelDirectory(for: manifest)
        guard Self.isDirectory(directory) else { throw ManagedLocalModelStoreError.missingModel }
        activeOperation = .generation(modelID)
        defer { activeOperation = nil }
        try Task.checkCancellation()
        try Self.verify(manifest, at: directory)
        try Task.checkCancellation()
        return try await operation(directory)
    }

    private func updateProgress(modelID: String, operationID: UUID, completedBytes: Int64) {
        guard case .download(let activeID, _) = activeOperation,
              activeID == modelID,
              currentOperationID == operationID
        else { return }
        activeOperation = .download(modelID, completedBytes)
    }

    private var currentOperationID: UUID?

    private func manifest(for id: String) -> ManagedLocalModelManifest? {
        manifests.first { $0.descriptor.id == id }
    }

    private func modelDirectory(for manifest: ManagedLocalModelManifest) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(manifest.storageName, isDirectory: true)
    }

    private static func validate(_ manifest: ManagedLocalModelManifest) throws {
        let modelComponents = manifest.descriptor.id.split(separator: "/", omittingEmptySubsequences: false)
        guard modelComponents.count == 2,
              modelComponents.allSatisfy({ $0.utf8.allSatisfy(isSafePathByte) }),
              manifest.descriptor.revision.utf8.count == 40,
              manifest.descriptor.revision.utf8.allSatisfy(isLowercaseHexByte),
              !manifest.storageName.isEmpty,
              manifest.storageName != ".",
              manifest.storageName != "..",
              manifest.storageName.utf8.allSatisfy(isSafePathByte),
              manifest.descriptor.downloadBytes > 0,
              !manifest.artifacts.isEmpty
        else { throw ManagedLocalModelStoreError.invalidManifest }
        var totalBytes: Int64 = 0
        var paths = Set<String>()
        for artifact in manifest.artifacts {
            let (nextTotalBytes, overflow) = totalBytes.addingReportingOverflow(artifact.byteCount)
            guard !overflow,
                  artifact.byteCount > 0,
                  artifact.sha256.count == 64,
                  artifact.sha256.utf8.allSatisfy(isLowercaseHexByte),
                  artifact.path != installReceiptName,
                  !artifact.path.hasPrefix("\(installReceiptName)/"),
                  (try? artifactURL(artifact.path, under: URL(fileURLWithPath: "/"))) != nil,
                  paths.insert(artifact.path).inserted
            else { throw ManagedLocalModelStoreError.invalidManifest }
            totalBytes = nextTotalBytes
        }
        guard totalBytes == manifest.descriptor.downloadBytes else { throw ManagedLocalModelStoreError.invalidManifest }
    }

    private static func sourceURL(for manifest: ManagedLocalModelManifest, artifact: ManagedLocalModelArtifact) throws -> URL {
        guard let url = URL(string: "https://huggingface.co/\(manifest.descriptor.id)/resolve/\(manifest.descriptor.revision)/\(artifact.path)"),
              isAllowedDownloadURL(url)
        else { throw ManagedLocalModelStoreError.invalidManifest }
        return url
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }

    private static func artifactURL(_ path: String, under directory: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy(isSafePathByte) })
        else { throw ManagedLocalModelStoreError.invalidManifest }
        return components.reduce(directory) { $0.appendingPathComponent(String($1)) }
    }

    private static func isSafePathByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95].contains(byte)
    }

    private static func isLowercaseHexByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    private static func ensureDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            guard isDirectory(directory) else { throw ManagedLocalModelStoreError.invalidInstalledModel }
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ManagedLocalModelStoreError.downloadFailed
        }
        guard isDirectory(directory) else { throw ManagedLocalModelStoreError.invalidInstalledModel }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isCompleteInstall(_ manifest: ManagedLocalModelManifest, at directory: URL) -> Bool {
        do {
            try verifyInstallLayoutAndSizes(manifest, at: directory)
            return true
        } catch {
            return false
        }
    }

    private static func isVerifiedInstall(_ manifest: ManagedLocalModelManifest, at directory: URL) throws -> Bool {
        do {
            try verify(manifest, at: directory)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private static func verify(_ manifest: ManagedLocalModelManifest, at directory: URL) throws {
        try verifyInstallLayoutAndSizes(manifest, at: directory)
        for artifact in manifest.artifacts {
            let url = try artifactURL(artifact.path, under: directory)
            try verify(artifact, at: url)
        }
    }

    private static func verifyInstallLayoutAndSizes(_ manifest: ManagedLocalModelManifest, at directory: URL) throws {
        let modelsDirectory = directory.deletingLastPathComponent()
        let rootDirectory = modelsDirectory.deletingLastPathComponent()
        guard isDirectory(rootDirectory), isDirectory(modelsDirectory), isDirectory(directory) else {
            throw ManagedLocalModelStoreError.invalidInstalledModel
        }
        try validate(manifest)

        let expectedPaths = Set(manifest.artifacts.map(\.path)).union([installReceiptName])
        var expectedDirectories = Set<String>()
        for path in expectedPaths {
            let components = path.split(separator: "/")
            if components.count > 1 {
                for count in 1..<components.count {
                    expectedDirectories.insert(components.prefix(count).joined(separator: "/"))
                }
            }
        }

        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw ManagedLocalModelStoreError.invalidInstalledModel }
        var foundPaths = Set<String>()
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ManagedLocalModelStoreError.invalidInstalledModel }
            let itemPath = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard itemPath.hasPrefix(directoryPath + "/") else { throw ManagedLocalModelStoreError.invalidInstalledModel }
            let path = String(itemPath.dropFirst(directoryPath.count + 1))
            if values.isDirectory == true {
                guard expectedDirectories.contains(path) else { throw ManagedLocalModelStoreError.invalidInstalledModel }
            } else {
                guard values.isRegularFile == true,
                      expectedPaths.contains(path),
                      foundPaths.insert(path).inserted
                else { throw ManagedLocalModelStoreError.invalidInstalledModel }
            }
        }
        guard foundPaths == expectedPaths else { throw ManagedLocalModelStoreError.invalidInstalledModel }

        for artifact in manifest.artifacts {
            let url = try artifactURL(artifact.path, under: directory)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  Int64(fileSize) == artifact.byteCount
            else { throw ManagedLocalModelStoreError.integrityMismatch }
        }

        let receiptURL = directory.appendingPathComponent(installReceiptName)
        guard let values = try? receiptURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= 65_536,
              let data = try? Data(contentsOf: receiptURL, options: .mappedIfSafe),
              let receipt = try? JSONDecoder().decode(ManagedLocalInstallReceipt.self, from: data),
              receipt == ManagedLocalInstallReceipt(manifest: manifest)
        else { throw ManagedLocalModelStoreError.invalidInstalledModel }
    }

    private static func itemExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func verify(_ artifact: ManagedLocalModelArtifact, at url: URL) throws {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              Int64(fileSize) == artifact.byteCount
        else { throw ManagedLocalModelStoreError.integrityMismatch }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == artifact.sha256 else { throw ManagedLocalModelStoreError.integrityMismatch }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ManagedLocalModelStoreError {
            throw error
        } catch {
            throw ManagedLocalModelStoreError.integrityMismatch
        }
    }

    private nonisolated static func transferArtifact(
        source: URL,
        destination: URL,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard isAllowedDownloadURL(source) else { throw ManagedLocalModelStoreError.invalidManifest }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let fileHandle = try? FileHandle(forWritingTo: destination)
        else { throw ManagedLocalModelStoreError.downloadFailed }

        let delegate = ArtifactTransferDelegate(fileHandle: fileHandle, expectedBytes: expectedBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1_800
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: source)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        do {
            try await delegate.download(request, in: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ManagedLocalModelStoreError {
            throw error
        } catch {
            throw ManagedLocalModelStoreError.downloadFailed
        }
    }
}

private final class ArtifactTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var receivedBytes: Int64 = 0
    private var failure: ManagedLocalModelStoreError?
    private var cancellationRequested = false

    init(fileHandle: FileHandle, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.fileHandle = fileHandle
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func download(_ request: URLRequest, in session: URLSession) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                let cancelled = cancellationRequested
                lock.unlock()
                if cancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, Self.isAllowed(url) else {
            fail(.unsafeRedirect, task: task)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              let url = httpResponse.url,
              Self.isAllowed(url),
              httpResponse.statusCode == 200
        else {
            fail(.downloadFailed, task: dataTask)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = httpResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard failure == nil, let response, response.statusCode == 200 else {
            lock.unlock()
            dataTask.cancel()
            return
        }
        let updatedBytes = receivedBytes + Int64(data.count)
        guard updatedBytes <= expectedBytes else {
            failure = .integrityMismatch
            lock.unlock()
            dataTask.cancel()
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
            receivedBytes = updatedBytes
        } catch {
            failure = .downloadFailed
            lock.unlock()
            dataTask.cancel()
            return
        }
        lock.unlock()
        progress(updatedBytes)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        let cancelled = cancellationRequested || (error as? URLError)?.code == .cancelled
        let receivedBytes = self.receivedBytes
        let hasSuccessfulResponse = response?.statusCode == 200
        lock.unlock()

        try? fileHandle.close()
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if error != nil || !hasSuccessfulResponse {
            continuation.resume(throwing: ManagedLocalModelStoreError.downloadFailed)
        } else if receivedBytes != expectedBytes {
            continuation.resume(throwing: ManagedLocalModelStoreError.integrityMismatch)
        } else {
            continuation.resume()
        }
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func fail(_ error: ManagedLocalModelStoreError, task: URLSessionTask) {
        lock.lock()
        failure = error
        lock.unlock()
        task.cancel()
    }

    private static func isAllowed(_ url: URL) -> Bool {
        ManagedLocalModelStore.isAllowedDownloadURL(url)
    }
}
