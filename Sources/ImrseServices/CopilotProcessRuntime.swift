#if os(macOS)
import CoreFoundation
import Darwin
import Foundation

public struct CopilotProcessRuntime: CopilotRuntime, Sendable {
    public static let supportedProtocolVersion = 3
    static let launchArguments = ["--headless", "--no-auto-update", "--log-level", "none", "--stdio", "--no-auto-login"]
    static let minimumVerifiedRuntimeVersion = "1.0.83-2"

    private let executableURL: URL
    private let timeout: Duration
    private let maximumOutputBytes: Int

    public init(
        executableURL: URL,
        timeout: Duration = .seconds(120),
        maximumOutputBytes: Int = 1_048_576
    ) {
        self.executableURL = executableURL
        self.timeout = timeout > .zero ? timeout : .seconds(1)
        self.maximumOutputBytes = min(max(maximumOutputBytes, 1), 4_194_304)
    }

    public func complete(
        _ request: CopilotRuntimeRequest,
        authentication: CopilotRuntimeAuthentication
    ) async throws -> String {
        guard executableURL.isFileURL,
              executableURL.pathExtension.lowercased() != "js",
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else { throw CopilotRuntimeError.runtimeUnavailable }

        let session = CopilotProcessSession(
            executableURL: executableURL,
            request: request,
            authentication: authentication,
            maximumOutputBytes: maximumOutputBytes
        )
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await session.run() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CopilotRuntimeError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CopilotRuntimeError.interrupted }
            return result
        }
    }

    static func runtimeEnvironment(home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "TMPDIR": home.path,
            "COPILOT_HOME": home.path,
            "COPILOT_DISABLE_KEYTAR": "1",
            "LANG": "en_US.UTF-8"
        ]
    }

    static func sessionCreateParameters(
        request: CopilotRuntimeRequest,
        sessionID: String,
        workingDirectory: URL
    ) -> [String: Any] {
        [
            "sessionId": sessionID,
            "model": request.model,
            "tools": [Any](),
            "availableTools": [String](),
            "excludedTools": [String](),
            "toolFilterPrecedence": "excluded",
            "systemMessage": [
                "mode": "customize",
                "sections": ["environment_context": ["action": "remove"]]
            ],
            "requestPermission": false,
            "requestUserInput": false,
            "requestElicitation": false,
            "requestCanvasRenderer": false,
            "requestExtensions": false,
            "requestExitPlanMode": false,
            "requestAutoModeSwitch": false,
            "hooks": false,
            "mcpServers": [String: Any](),
            "mcpOAuthTokenStorage": "in-memory",
            "customAgents": [Any](),
            "customAgentsLocalOnly": true,
            "skillDirectories": [String](),
            "pluginDirectories": [String](),
            "instructionDirectories": [String](),
            "disabledSkills": [String](),
            "disabledMcpServers": [String](),
            "enableConfigDiscovery": false,
            "enableSkills": false,
            "enableFileHooks": false,
            "enableHostGitOperations": false,
            "enableSessionStore": false,
            "memory": ["enabled": false],
            "skipEmbeddingRetrieval": true,
            "embeddingCacheStorage": "in-memory",
            "infiniteSessions": ["enabled": false],
            "enableSessionTelemetry": false,
            "isExperimentalMode": false,
            "enableCitations": false,
            "enableFileChangeTracking": false,
            "skipCustomInstructions": true,
            "enableOnDemandInstructionDiscovery": false,
            "remoteSession": "off",
            "enableManagedSettings": false,
            "workingDirectory": workingDirectory.path,
            "additionalDirectories": [String](),
            "streaming": true,
            "includeSubAgentStreamingEvents": false
        ]
    }

    static func supportsPrivacyBaseline(runtimeVersion: String) -> Bool {
        let versionParts = runtimeVersion.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let baselineParts = minimumVerifiedRuntimeVersion.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        let baselineCore = baselineParts[0].split(separator: ".", omittingEmptySubsequences: false)
        let versionNumbers = core.compactMap { Int($0) }
        let baselineNumbers = baselineCore.compactMap { Int($0) }
        guard versionNumbers.count == 3,
              baselineNumbers.count == 3,
              zip(core, versionNumbers).allSatisfy({ String($0.0) == String($0.1) }),
              zip(baselineCore, baselineNumbers).allSatisfy({ String($0.0) == String($0.1) }),
              baselineParts.count == 2
        else { return false }

        for (versionNumber, baselineNumber) in zip(versionNumbers, baselineNumbers) {
            if versionNumber != baselineNumber {
                return versionNumber > baselineNumber && versionParts.count == 1
            }
        }

        return versionParts.count == 1 || versionParts[1] == baselineParts[1]
    }

    static func sessionOptionsParameters(sessionID: String) -> [String: Any] {
        [
            "sessionId": sessionID,
            "skipCustomInstructions": true,
            "customAgentsLocalOnly": true,
            "coauthorEnabled": false,
            "manageScheduleEnabled": false,
            "installedPlugins": [String](),
            "includedBuiltinSkills": [String]()
        ]
    }
}

private struct CopilotRPCPayload: @unchecked Sendable {
    let values: [String: Any]
}

private struct CopilotRPCResult: @unchecked Sendable {
    let value: Any
}

private struct CopilotPipeHandles: @unchecked Sendable {
    let input: FileHandle
    let output: FileHandle
}

private actor CopilotEphemeralSessionFileSystem {
    private enum Node {
        case directory(created: Date, modified: Date)
        case file(content: String, created: Date, modified: Date)
    }

    private let maximumFileBytes = 16 * 1_024 * 1_024
    private let maximumSessionBytes = 16 * 1_024 * 1_024
    private let maximumEntryCount = 4_096
    private var sessions: [String: [String: Node]] = [:]

    func handle(
        _ method: String,
        message: CopilotRPCPayload,
        sessionID: String
    ) throws -> CopilotRPCResult {
        guard let parameters = message.values["params"] as? [String: Any],
              parameters["sessionId"] as? String == sessionID
        else { throw CopilotRuntimeError.malformedResponse }

        var nodes = sessions[sessionID] ?? ["/": .directory(created: Date(), modified: Date())]
        let result: Any
        switch method {
        case "sessionFs.readFile":
            guard let path = Self.normalizedPath(parameters["path"] as? String),
                  case .file(let content, _, _)? = nodes[path]
            else {
                result = ["content": "", "error": Self.fileError("ENOENT")]
                return CopilotRPCResult(value: result)
            }
            result = ["content": content]
        case "sessionFs.writeFile":
            guard let path = Self.normalizedPath(parameters["path"] as? String),
                  path != "/",
                  let content = parameters["content"] as? String,
                  Self.createDirectory(Self.parent(of: path), recursive: true, nodes: &nodes) == nil
            else { return CopilotRPCResult(value: Self.fileError("ENOENT")) }
            guard Self.isFileOrMissing(nodes[path]),
                  Self.canStore(
                    content,
                    replacing: nodes[path],
                    in: nodes,
                    maximumFileBytes: maximumFileBytes,
                    maximumSessionBytes: maximumSessionBytes
                  )
            else { return CopilotRPCResult(value: Self.fileError("UNKNOWN")) }
            let timestamp = Date()
            let created = Self.createdAt(nodes[path]) ?? timestamp
            nodes[path] = .file(content: content, created: created, modified: timestamp)
            sessions[sessionID] = nodes
            result = NSNull()
        case "sessionFs.appendFile":
            guard let path = Self.normalizedPath(parameters["path"] as? String), path != "/",
                  let content = parameters["content"] as? String
            else { return CopilotRPCResult(value: Self.fileError("ENOENT")) }
            let parent = Self.parent(of: path)
            guard Self.createDirectory(parent, recursive: true, nodes: &nodes) == nil,
                  Self.isFileOrMissing(nodes[path])
            else { return CopilotRPCResult(value: Self.fileError("UNKNOWN")) }
            let oldContent = Self.contents(nodes[path]) ?? ""
            let appended = oldContent + content
            guard Self.canStore(appended, replacing: nodes[path], in: nodes,
                                maximumFileBytes: maximumFileBytes,
                                maximumSessionBytes: maximumSessionBytes)
            else { return CopilotRPCResult(value: Self.fileError("UNKNOWN")) }
            let timestamp = Date()
            let created = Self.createdAt(nodes[path]) ?? timestamp
            nodes[path] = .file(content: appended, created: created, modified: timestamp)
            sessions[sessionID] = nodes
            result = NSNull()
        case "sessionFs.exists":
            let path = Self.normalizedPath(parameters["path"] as? String)
            result = ["exists": path.map { nodes[$0] != nil } ?? false]
        case "sessionFs.stat":
            guard let path = Self.normalizedPath(parameters["path"] as? String), let node = nodes[path] else {
                result = Self.statError()
                return CopilotRPCResult(value: result)
            }
            switch node {
            case .directory(let created, let modified):
                result = Self.statResult(isFile: false, isDirectory: true, size: 0, created: created, modified: modified)
            case .file(let content, let created, let modified):
                result = Self.statResult(isFile: true, isDirectory: false, size: content.utf8.count,
                                         created: created, modified: modified)
            }
        case "sessionFs.mkdir":
            guard let path = Self.normalizedPath(parameters["path"] as? String) else {
                return CopilotRPCResult(value: Self.fileError("ENOENT"))
            }
            let error = Self.createDirectory(path, recursive: parameters["recursive"] as? Bool == true, nodes: &nodes)
            if let error { return CopilotRPCResult(value: Self.fileError(error)) }
            sessions[sessionID] = nodes
            result = NSNull()
        case "sessionFs.readdir", "sessionFs.readdirWithTypes":
            guard let path = Self.normalizedPath(parameters["path"] as? String),
                  case .directory? = nodes[path]
            else {
                if method == "sessionFs.readdir" {
                    result = ["entries": [String](), "error": Self.fileError("ENOENT")]
                } else {
                    result = ["entries": [[String: String]](), "error": Self.fileError("ENOENT")]
                }
                return CopilotRPCResult(value: result)
            }
            let children = Self.children(of: path, in: nodes)
            if method == "sessionFs.readdir" {
                result = ["entries": children.map(\.name)]
            } else {
                result = ["entries": children.map { ["name": $0.name, "type": $0.isDirectory ? "directory" : "file"] }]
            }
        case "sessionFs.rm":
            guard let path = Self.normalizedPath(parameters["path"] as? String), path != "/" else {
                return CopilotRPCResult(value: Self.fileError("UNKNOWN"))
            }
            guard nodes[path] != nil else {
                if parameters["force"] as? Bool == true { return CopilotRPCResult(value: NSNull()) }
                return CopilotRPCResult(value: Self.fileError("ENOENT"))
            }
            let recursive = parameters["recursive"] as? Bool == true
            let childPaths = nodes.keys.filter { $0.hasPrefix(path + "/") }
            if case .directory? = nodes[path], !recursive, !childPaths.isEmpty {
                return CopilotRPCResult(value: Self.fileError("UNKNOWN"))
            }
            nodes = nodes.filter { $0.key != path && !(recursive && $0.key.hasPrefix(path + "/")) }
            sessions[sessionID] = nodes
            result = NSNull()
        case "sessionFs.rename":
            guard let source = Self.normalizedPath(parameters["src"] as? String),
                  let destination = Self.normalizedPath(parameters["dest"] as? String),
                  source != "/", destination != "/", source != destination,
                  !destination.hasPrefix(source + "/"), !source.hasPrefix(destination + "/"), nodes[source] != nil,
                  case .directory? = nodes[Self.parent(of: destination)]
            else { return CopilotRPCResult(value: Self.fileError("ENOENT")) }
            if nodes[destination] != nil {
                nodes = nodes.filter { $0.key != destination && !$0.key.hasPrefix(destination + "/") }
            }
            let moving = nodes.filter { $0.key == source || $0.key.hasPrefix(source + "/") }
            nodes = nodes.filter { $0.key != source && !$0.key.hasPrefix(source + "/") }
            for (path, node) in moving {
                let suffix = path.dropFirst(source.count)
                nodes[destination + String(suffix)] = node
            }
            guard nodes.count <= maximumEntryCount, Self.totalBytes(in: nodes) <= maximumSessionBytes else {
                return CopilotRPCResult(value: Self.fileError("UNKNOWN"))
            }
            sessions[sessionID] = nodes
            result = NSNull()
        default:
            throw CopilotRuntimeError.incompatibleRuntime
        }
        return CopilotRPCResult(value: result)
    }

    func discard(sessionID: String) {
        sessions.removeValue(forKey: sessionID)
    }

    func preflight(sessionID: String) throws {
        let path = "/.imrse-preflight-\(UUID().uuidString)/nested/state"
        let parameters: [String: Any] = [
            "sessionId": sessionID,
            "path": path,
            "content": "session-filesystem-ready"
        ]
        let write = try handle(
            "sessionFs.writeFile",
            message: CopilotRPCPayload(values: ["params": parameters]),
            sessionID: sessionID
        )
        guard write.value is NSNull else { throw CopilotRuntimeError.incompatibleRuntime }

        let read = try handle(
            "sessionFs.readFile",
            message: CopilotRPCPayload(values: ["params": ["sessionId": sessionID, "path": path]]),
            sessionID: sessionID
        )
        guard (read.value as? [String: Any])?["content"] as? String == "session-filesystem-ready" else {
            throw CopilotRuntimeError.incompatibleRuntime
        }
    }

    private static func normalizedPath(_ rawPath: String?) -> String? {
        guard let rawPath, !rawPath.isEmpty, rawPath.utf8.count <= 4_096,
              !rawPath.hasPrefix("~"), !rawPath.contains("\0"),
              !rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return nil }
        return "/" + components.filter { $0 != "." }.joined(separator: "/")
    }

    private static func parent(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/"), separator != path.startIndex else { return "/" }
        return String(path[..<separator])
    }

    private static func createDirectory(_ path: String, recursive: Bool, nodes: inout [String: Node]) -> String? {
        if case .directory? = nodes[path] { return nil }
        if nodes[path] != nil { return "UNKNOWN" }
        if path == "/" {
            nodes[path] = .directory(created: Date(), modified: Date())
            return nil
        }
        let parent = parent(of: path)
        if case .directory? = nodes[parent] {
            nodes[path] = .directory(created: Date(), modified: Date())
            return nodes.count <= 4_096 ? nil : "UNKNOWN"
        }
        guard recursive else { return "ENOENT" }
        guard createDirectory(parent, recursive: true, nodes: &nodes) == nil else { return "ENOENT" }
        nodes[path] = .directory(created: Date(), modified: Date())
        return nodes.count <= 4_096 ? nil : "UNKNOWN"
    }

    private static func contents(_ node: Node?) -> String? {
        guard case .file(let content, _, _)? = node else { return nil }
        return content
    }

    private static func createdAt(_ node: Node?) -> Date? {
        switch node {
        case .directory(let created, _), .file(_, let created, _): created
        case nil: nil
        }
    }

    private static func isFileOrMissing(_ node: Node?) -> Bool {
        if case .directory? = node { return false }
        return true
    }

    private static func canStore(
        _ content: String,
        replacing node: Node?,
        in nodes: [String: Node],
        maximumFileBytes: Int,
        maximumSessionBytes: Int
    ) -> Bool {
        let byteCount = content.utf8.count
        let oldSize = contents(node)?.utf8.count ?? 0
        return byteCount <= maximumFileBytes
            && totalBytes(in: nodes) - oldSize <= maximumSessionBytes - byteCount
            && (node != nil || nodes.count < 4_096)
    }

    private static func totalBytes(in nodes: [String: Node]) -> Int {
        nodes.values.reduce(into: 0) { total, node in
            total += contents(node)?.utf8.count ?? 0
        }
    }

    private static func children(of path: String, in nodes: [String: Node]) -> [(name: String, isDirectory: Bool)] {
        let prefix = path == "/" ? "/" : path + "/"
        return nodes.keys.compactMap { candidate in
            guard candidate.hasPrefix(prefix) else { return nil }
            let name = candidate.dropFirst(prefix.count)
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return (String(name), isDirectory(nodes[candidate]))
        }.sorted { $0.name < $1.name }
    }

    private static func isDirectory(_ node: Node?) -> Bool {
        if case .directory? = node { return true }
        return false
    }

    private static func fileError(_ code: String) -> [String: String] { ["code": code] }

    private static func statResult(isFile: Bool, isDirectory: Bool, size: Int, created: Date, modified: Date) -> [String: Any] {
        [
            "isFile": isFile,
            "isDirectory": isDirectory,
            "size": size,
            "mtime": ISO8601DateFormatter().string(from: modified),
            "birthtime": ISO8601DateFormatter().string(from: created)
        ]
    }

    private static func statError() -> [String: Any] {
        let now = ISO8601DateFormatter().string(from: Date())
        return ["isFile": false, "isDirectory": false, "size": 0, "mtime": now, "birthtime": now, "error": fileError("ENOENT")]
    }
}

private actor CopilotProcessSession {
    private let executableURL: URL
    private let request: CopilotRuntimeRequest
    private let authentication: CopilotRuntimeAuthentication
    private let maximumOutputBytes: Int
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var isolatedHome: URL?

    init(
        executableURL: URL,
        request: CopilotRuntimeRequest,
        authentication: CopilotRuntimeAuthentication,
        maximumOutputBytes: Int
    ) {
        self.executableURL = executableURL
        self.request = request
        self.authentication = authentication
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run() async throws -> String {
        try await withTaskCancellationHandler {
            try await runProcess()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() {
        terminateProcess()
    }

    private func runProcess() async throws -> String {
        do {
            try Task.checkCancellation()
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("imrse-copilot-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            isolatedHome = home

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw CopilotRuntimeError.runtimeFailed
            }
            process.executableURL = executableURL
            process.arguments = CopilotProcessRuntime.launchArguments
            process.currentDirectoryURL = home
            process.environment = CopilotProcessRuntime.runtimeEnvironment(home: home)
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe

            do {
                try process.run()
            } catch {
                throw CopilotRuntimeError.runtimeUnavailable
            }

            let sessionID = UUID().uuidString.lowercased()
            let connection = CopilotJSONRPCConnection(
                pipes: CopilotPipeHandles(
                    input: inputPipe.fileHandleForWriting,
                    output: outputPipe.fileHandleForReading
                ),
                sessionID: sessionID,
                maximumOutputBytes: maximumOutputBytes
            )
            let handshake = try await connection.request("connect", parameters: [
                "supportedTaskKinds": ["agent", "client", "shell"]
            ])
            guard handshake.values["ok"] as? Bool == true,
                  handshake.values["protocolVersion"] as? Int == CopilotProcessRuntime.supportedProtocolVersion,
                  let runtimeVersion = handshake.values["version"] as? String,
                  CopilotProcessRuntime.supportsPrivacyBaseline(runtimeVersion: runtimeVersion)
            else { throw CopilotRuntimeError.incompatibleRuntime }

            let sessionFS = try await connection.request("sessionFs.setProvider", parameters: [
                "initialCwd": home.path,
                "sessionStatePath": "/session-state",
                "conventions": "posix",
                "capabilities": ["sqlite": false]
            ])
            guard sessionFS.values["success"] as? Bool == true else {
                throw CopilotRuntimeError.incompatibleRuntime
            }
            try await connection.preflightSessionFiles()

            let createParameters = CopilotProcessRuntime.sessionCreateParameters(
                request: request,
                sessionID: sessionID,
                workingDirectory: home
            )
            let created = try await connection.request("session.create", parameters: createParameters)
            guard created.values["sessionId"] as? String == sessionID else {
                throw CopilotRuntimeError.malformedResponse
            }

            let optionsUpdated = try await connection.request(
                "session.options.update",
                parameters: CopilotProcessRuntime.sessionOptionsParameters(sessionID: sessionID)
            )
            guard optionsUpdated.values["success"] as? Bool == true else {
                throw CopilotRuntimeError.incompatibleRuntime
            }

            guard case .staticToken(let accessToken, let login) = authentication else {
                throw CopilotRuntimeError.authenticationFailed
            }
            let authInfo = try await connection.request("session.gitHubAuth.login", parameters: [
                "sessionId": sessionID,
                "host": "https://github.com",
                "login": login,
                "token": accessToken,
                "persist": false
            ])
            guard authInfo.values["type"] as? String == "token",
                  authInfo.values["host"] as? String == "https://github.com"
            else { throw CopilotRuntimeError.authenticationFailed }
            await connection.markAuthenticated()

            let prompt = Self.prompt(for: request)
            let sent = try await connection.request("session.send", parameters: [
                "sessionId": sessionID,
                "prompt": prompt
            ])
            guard sent.values["messageId"] is String else {
                throw CopilotRuntimeError.malformedResponse
            }

            let output = try await connection.waitForCompletion()
            try await stopSession(connection: connection, sessionID: sessionID)
            terminateProcess()
            removeTemporaryDirectory()
            return output
        } catch {
            terminateProcess()
            removeTemporaryDirectory()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func stopSession(connection: CopilotJSONRPCConnection, sessionID: String) async throws {
        let detached = try await connection.request("session.detach", parameters: ["sessionId": sessionID])
        guard detached.values["success"] as? Bool == true else { throw CopilotRuntimeError.runtimeFailed }
        let deleted = try await connection.request("session.delete", parameters: ["sessionId": sessionID])
        guard deleted.values["success"] as? Bool == true else { throw CopilotRuntimeError.runtimeFailed }
        await connection.discardSessionFiles()
        _ = try await connection.request("runtime.shutdown", parameters: [:])
        inputPipe?.fileHandleForWriting.closeFile()
        await waitForProcessExit()
    }

    private func waitForProcessExit() async {
        guard let process, process.isRunning else { return }
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { terminateProcess() }
    }

    private func terminateProcess() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let identifier = process.processIdentifier
        let deadline = ContinuousClock.now + .milliseconds(250)
        while process.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { Darwin.kill(identifier, SIGKILL) }
    }

    private func removeTemporaryDirectory() {
        if let isolatedHome {
            try? FileManager.default.removeItem(at: isolatedHome)
            self.isolatedHome = nil
        }
        inputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.closeFile()
        inputPipe = nil
        outputPipe = nil
    }

    private static func prompt(for request: CopilotRuntimeRequest) -> String {
        "\(request.instruction)\n\nSelected text:\n\(request.text)"
    }
}

private actor CopilotJSONRPCConnection {
    private let pipes: CopilotPipeHandles
    private let sessionID: String
    private let sessionFileSystem = CopilotEphemeralSessionFileSystem()
    private let maximumOutputBytes: Int
    private let maximumFrameBytes: Int
    private var buffer = Data()
    private var nextRequestID = 1
    private var pendingResponses: [Int: CopilotRPCPayload] = [:]
    private var didSendPrompt = false
    private var didComplete = false
    private var didAuthenticate = false
    private var streamedBytes = 0
    private var finalBytes = 0
    private var finalMessageIDs = Set<String>()
    private var finalMessages: [(order: Int, chunk: Int?, apiCallID: String, text: String)] = []
    private var generationUsage: [String: (finishReason: String, contentFilterTriggered: Bool)] = [:]
    private var eventOrder = 0

    init(
        pipes: CopilotPipeHandles,
        sessionID: String,
        maximumOutputBytes: Int
    ) {
        self.pipes = pipes
        self.sessionID = sessionID
        self.maximumOutputBytes = maximumOutputBytes
        maximumFrameBytes = maximumOutputBytes + 16 * 1_024 * 1_024
    }

    func request(_ method: String, parameters: [String: Any]) async throws -> CopilotRPCPayload {
        if method == "session.send" { didSendPrompt = true }
        let requestID = nextRequestID
        nextRequestID += 1
        try write([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": parameters
        ])

        if let pending = pendingResponses.removeValue(forKey: requestID) {
            return try resultPayload(pending, method: method)
        }

        while true {
            try Task.checkCancellation()
            let message = try await readMessage()
            let fields = message.values
            if fields["method"] == nil, let responseID = Self.numericID(fields["id"]) {
                if responseID == requestID { return try resultPayload(message, method: method) }
                pendingResponses[responseID] = message
                continue
            }
            try await handleMessage(message)
        }
    }

    func waitForCompletion() async throws -> String {
        while !didComplete {
            try Task.checkCancellation()
            let message = try await readMessage()
            if message.values["method"] == nil, let responseID = Self.numericID(message.values["id"]) {
                pendingResponses[responseID] = message
                continue
            }
            try await handleMessage(message)
        }

        guard didAuthenticate else { throw CopilotRuntimeError.authenticationFailed }
        guard !finalMessages.isEmpty else { throw CopilotRuntimeError.emptyOutput }
        guard hasSuccessfulGenerationMetadata else { throw CopilotRuntimeError.interrupted }
        let ordered = finalMessages.sorted { left, right in
            if let leftChunk = left.chunk, let rightChunk = right.chunk, leftChunk != rightChunk {
                return leftChunk < rightChunk
            }
            return left.order < right.order
        }
        let output = ordered.map(\.text).joined()
        guard output.utf8.count <= maximumOutputBytes else { throw CopilotRuntimeError.outputTooLarge }
        return output
    }

    func markAuthenticated() {
        didAuthenticate = true
    }

    func discardSessionFiles() async {
        await sessionFileSystem.discard(sessionID: sessionID)
    }

    func preflightSessionFiles() async throws {
        try await sessionFileSystem.preflight(sessionID: sessionID)
    }

    private var hasSuccessfulGenerationMetadata: Bool {
        !generationUsage.isEmpty
            && generationUsage.values.allSatisfy { $0.finishReason == "stop" && !$0.contentFilterTriggered }
            && finalMessages.allSatisfy { generationUsage[$0.apiCallID] != nil }
    }

    private func handleMessage(_ message: CopilotRPCPayload) async throws {
        let fields = message.values
        guard let method = fields["method"] as? String else { throw CopilotRuntimeError.malformedResponse }
        if fields["id"] != nil {
            try await handleRequest(method, message: message)
            return
        }
        if method == "session.event" {
            try await handleSessionEvent(message)
        }
    }

    private func handleRequest(_ method: String, message: CopilotRPCPayload) async throws {
        guard let id = message.values["id"] else { throw CopilotRuntimeError.malformedResponse }
        if method.hasPrefix("sessionFs.") {
            do {
                let result = try await sessionFileSystem.handle(method, message: message, sessionID: sessionID)
                try write(["jsonrpc": "2.0", "id": id, "result": result.value])
            } catch {
                try write([
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": ["code": -32601, "message": "The session filesystem operation is not supported."]
                ])
                if let error = error as? CopilotRuntimeError { throw error }
                throw CopilotRuntimeError.runtimeFailed
            }
            return
        }

        try write([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": method == "gitHubToken.getToken" ? -32001 : -32601,
                "message": method == "gitHubToken.getToken"
                    ? "GitHub authentication is unavailable."
                    : "Request is not supported."
            ]
        ])
        if method == "gitHubToken.getToken" {
            throw CopilotRuntimeError.authenticationFailed
        }
        if method.localizedCaseInsensitiveContains("permission") {
            throw CopilotRuntimeError.permissionDenied
        }
        if method.localizedCaseInsensitiveContains("tool") || method.localizedCaseInsensitiveContains("workflow") {
            throw CopilotRuntimeError.toolRequestDenied
        }
        throw CopilotRuntimeError.runtimeFailed
    }

    private func handleSessionEvent(_ message: CopilotRPCPayload) async throws {
        guard let parameters = message.values["params"] as? [String: Any],
              parameters["sessionId"] as? String == sessionID,
              let event = parameters["event"] as? [String: Any],
              let type = event["type"] as? String
        else { throw CopilotRuntimeError.malformedResponse }

        let data = event["data"] as? [String: Any] ?? [:]
        if event["agentId"] != nil || type.hasPrefix("subagent.") {
            throw CopilotRuntimeError.toolRequestDenied
        }

        switch type {
        case "permission.requested":
            guard let requestID = data["requestId"] as? String else {
                throw CopilotRuntimeError.malformedResponse
            }
            if data["resolvedByHook"] as? Bool != true {
                let response = try await request("session.permissions.handlePendingPermissionRequest", parameters: [
                    "requestId": requestID,
                    "result": ["kind": "reject", "feedback": "Tool use is disabled."]
                ])
                guard response.values["success"] as? Bool == true else {
                    throw CopilotRuntimeError.permissionDenied
                }
            }
            throw CopilotRuntimeError.permissionDenied
        case "external_tool.requested":
            guard let requestID = data["requestId"] as? String else {
                throw CopilotRuntimeError.malformedResponse
            }
            let response = try await request("session.tools.handlePendingToolCall", parameters: [
                "requestId": requestID,
                "error": "Tools are disabled."
            ])
            guard response.values["success"] as? Bool == true else {
                throw CopilotRuntimeError.toolRequestDenied
            }
            throw CopilotRuntimeError.toolRequestDenied
        case "assistant.message_delta":
            guard didSendPrompt,
                  let delta = data["deltaContent"] as? String
            else { throw CopilotRuntimeError.malformedResponse }
            streamedBytes += delta.utf8.count
            guard streamedBytes <= maximumOutputBytes else { throw CopilotRuntimeError.outputTooLarge }
        case "assistant.usage":
            guard didSendPrompt,
                  let apiCallID = data["apiCallId"] as? String,
                  !apiCallID.isEmpty,
                  apiCallID.utf8.count <= 256,
                  let finishReason = data["finishReason"] as? String,
                  let contentFilterTriggered = data["contentFilterTriggered"] as? Bool,
                  generationUsage[apiCallID] == nil
            else { throw CopilotRuntimeError.malformedResponse }
            generationUsage[apiCallID] = (
                finishReason: finishReason,
                contentFilterTriggered: contentFilterTriggered
            )
        case "assistant.message":
            guard didSendPrompt,
                  let messageID = data["messageId"] as? String,
                  let content = data["content"] as? String
            else { throw CopilotRuntimeError.malformedResponse }
            if let requests = data["toolRequests"] as? [Any], !requests.isEmpty {
                throw CopilotRuntimeError.toolRequestDenied
            }
            if let phase = data["phase"] as? String, phase != "final_answer" { return }
            guard let apiCallID = data["apiCallId"] as? String,
                  !apiCallID.isEmpty,
                  apiCallID.utf8.count <= 256
            else { throw CopilotRuntimeError.malformedResponse }
            guard finalMessageIDs.insert(messageID).inserted else { return }
            finalBytes += content.utf8.count
            guard finalBytes <= maximumOutputBytes else { throw CopilotRuntimeError.outputTooLarge }
            let chunk = data["chunkIndex"] as? Int
            finalMessages.append((order: eventOrder, chunk: chunk, apiCallID: apiCallID, text: content))
            eventOrder += 1
        case "session.error":
            throw CopilotRuntimeError.runtimeFailed
        case "session.idle":
            guard didSendPrompt else { return }
            if data["mode"] as? String == "autopilot" { return }
            if data["aborted"] as? Bool == true { throw CopilotRuntimeError.interrupted }
            guard didAuthenticate else { throw CopilotRuntimeError.authenticationFailed }
            guard !finalMessages.isEmpty else { throw CopilotRuntimeError.emptyOutput }
            guard hasSuccessfulGenerationMetadata else { throw CopilotRuntimeError.interrupted }
            didComplete = true
        case "assistant.tool_call_delta", "tool.execution_start", "tool.execution_complete":
            throw CopilotRuntimeError.toolRequestDenied
        default:
            break
        }
    }

    private func readMessage() async throws -> CopilotRPCPayload {
        while true {
            if let separator = buffer.range(of: Data([13, 10, 13, 10])) {
                guard separator.lowerBound <= 8_192 else { throw CopilotRuntimeError.outputTooLarge }
                let header = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
                let lengths = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2,
                              parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
                        else { return nil }
                        return Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                guard lengths.count == 1,
                      let contentLength = lengths.first,
                      contentLength > 0,
                      contentLength <= maximumFrameBytes
                else { throw CopilotRuntimeError.malformedResponse }

                let payloadStart = separator.upperBound
                let payloadEnd = payloadStart + contentLength
                guard buffer.count >= payloadEnd else {
                    try await readMore()
                    continue
                }
                let payload = buffer.subdata(in: payloadStart..<payloadEnd)
                buffer.removeSubrange(0..<payloadEnd)
                guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      object["jsonrpc"] as? String == "2.0"
                else { throw CopilotRuntimeError.malformedResponse }
                return CopilotRPCPayload(values: object)
            }

            guard buffer.count <= 8_192 else { throw CopilotRuntimeError.malformedResponse }
            try await readMore()
        }
    }

    private func readMore() async throws {
        try Task.checkCancellation()
        let descriptor = pipes.output.fileDescriptor
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = bytes.withUnsafeMutableBytes { storage in
                        Darwin.read(descriptor, storage.baseAddress, storage.count)
                    }
                    if count > 0 {
                        continuation.resume(returning: Data(bytes.prefix(count)))
                        return
                    }
                    if count == 0 {
                        continuation.resume(throwing: CopilotRuntimeError.interrupted)
                        return
                    }
                    if errno != EINTR {
                        continuation.resume(throwing: CopilotRuntimeError.runtimeFailed)
                        return
                    }
                }
            }
        }
        try Task.checkCancellation()
        buffer.append(data)
        guard buffer.count <= maximumFrameBytes + 8_192 else { throw CopilotRuntimeError.outputTooLarge }
    }

    private func resultPayload(_ response: CopilotRPCPayload, method: String) throws -> CopilotRPCPayload {
        guard response.values["error"] == nil else {
            if method == "session.gitHubAuth.login" { throw CopilotRuntimeError.authenticationFailed }
            if method == "sessionFs.setProvider" { throw CopilotRuntimeError.incompatibleRuntime }
            throw CopilotRuntimeError.runtimeFailed
        }
        guard let result = response.values["result"] else { throw CopilotRuntimeError.malformedResponse }
        if result is NSNull { return CopilotRPCPayload(values: [:]) }
        guard let values = result as? [String: Any] else { throw CopilotRuntimeError.malformedResponse }
        return CopilotRPCPayload(values: values)
    }

    private func write(_ object: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw CopilotRuntimeError.malformedResponse
        }
        let header = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        var frame = header
        frame.append(data)
        try pipes.input.write(contentsOf: frame)
    }

    private static func numericID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= Double(Int.max)
        else { return nil }
        return number.intValue
    }
}
#endif
