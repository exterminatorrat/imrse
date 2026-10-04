import AppKit
import Foundation
import Network

@MainActor
public final class OfficialAccountSignInCoordinator {
    private let openBrowser: @MainActor (URL) -> Bool
    private var listener: NWListener?
    private var runID: UUID?
    private var callbackURL: URL?
    private var readiness: CheckedContinuation<URL, any Error>?
    private var callback: CheckedContinuation<URL, any Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var callbackTimeoutTask: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]

    public init(openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openBrowser = openBrowser
    }

    public func prepareCallback() async throws -> URL {
        guard !Task.isCancelled else { throw OfficialAccountSignInCoordinatorError.cancelled }
        guard listener == nil, callback == nil, readiness == nil else {
            throw OfficialAccountSignInCoordinatorError.alreadyActive
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw OfficialAccountSignInCoordinatorError.listenerUnavailable
        }
        guard !Task.isCancelled else {
            listener.cancel()
            throw OfficialAccountSignInCoordinatorError.cancelled
        }
        let currentRun = UUID()
        self.listener = listener
        runID = currentRun
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                readiness = continuation
                guard !Task.isCancelled else {
                    finish(error: .cancelled, runID: currentRun)
                    return
                }
                readyTimeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    self?.finish(error: .timedOut, runID: currentRun)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in self?.listenerStateChanged(state, runID: currentRun) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in self?.accept(connection, runID: currentRun) }
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(runID: currentRun) }
        }
    }

    public func openAndWait(for authorizationURL: URL, timeout: Duration = .seconds(180)) async throws -> URL {
        guard !Task.isCancelled else { throw OfficialAccountSignInCoordinatorError.cancelled }
        guard let listener, let currentRun = runID, callbackURL != nil, callback == nil,
              Self.isOfficialAuthorizationURL(authorizationURL)
        else { throw OfficialAccountSignInCoordinatorError.invalidAuthorizationURL }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                callback = continuation
                guard !Task.isCancelled else {
                    finish(error: .cancelled, runID: currentRun)
                    return
                }
                callbackTimeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(error: .timedOut, runID: currentRun)
                }
                guard !Task.isCancelled else {
                    finish(error: .cancelled, runID: currentRun)
                    return
                }
                guard openBrowser(authorizationURL) else {
                    finish(error: .browserUnavailable, runID: currentRun)
                    return
                }
                guard self.listener === listener, callbackURL != nil else {
                    finish(error: .listenerUnavailable, runID: currentRun)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(runID: currentRun) }
        }
    }

    @discardableResult
    public func openDeviceVerificationPage(for url: URL) -> Bool {
        guard Self.isOfficialDeviceVerificationURL(url) else { return false }
        return openBrowser(url)
    }

    public func cancel() {
        guard let currentRun = runID else { return }
        cancel(runID: currentRun)
    }

    private func cancel(runID: UUID) {
        guard self.runID == runID else { return }
        finish(error: .cancelled, runID: runID)
    }

    private func listenerStateChanged(_ state: NWListener.State, runID: UUID) {
        guard self.runID == runID else { return }
        switch state {
        case .ready:
            guard readiness != nil,
                  let port = listener?.port,
                  let callbackURL = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")
            else { return }
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            self.callbackURL = callbackURL
            let continuation = readiness
            readiness = nil
            continuation?.resume(returning: callbackURL)
        case .failed:
            finish(error: .listenerUnavailable, runID: runID)
        case .cancelled:
            if readiness != nil || callback != nil { finish(error: .cancelled, runID: runID) }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, runID: UUID) {
        guard self.runID == runID, connections.count < 8 else {
            connection.cancel()
            return
        }
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        requestBuffers[identifier] = Data()
        connection.start(queue: .main)
        receiveNext(on: connection, identifier: identifier, runID: runID)
    }

    private func receiveNext(on connection: NWConnection, identifier: ObjectIdentifier, runID: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID else { connection.cancel(); return }
                if let data { self.requestBuffers[identifier, default: Data()].append(data) }
                guard self.requestBuffers[identifier, default: Data()].count <= 32_768 else {
                    self.respond(on: connection, identifier: identifier, status: 400, runID: runID)
                    return
                }
                if self.requestBuffers[identifier, default: Data()].range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handleRequest(on: connection, identifier: identifier, runID: runID)
                    return
                }
                if error != nil || isComplete {
                    connection.cancel()
                    self.connections.removeValue(forKey: identifier)
                    self.requestBuffers.removeValue(forKey: identifier)
                    return
                }
                self.receiveNext(on: connection, identifier: identifier, runID: runID)
            }
        }
    }

    private func handleRequest(on connection: NWConnection, identifier: ObjectIdentifier, runID: UUID) {
        guard let buffer = requestBuffers[identifier],
              let range = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: buffer[..<range.lowerBound], encoding: .utf8)
        else {
            respond(on: connection, identifier: identifier, status: 400, runID: runID)
            return
        }
        let lines = headers.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let hostHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
        let host = hostHeader.map { $0.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard requestLine.count == 3,
              requestLine[0] == "GET",
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              let callbackURL,
              host == "127.0.0.1:\(callbackURL.port ?? 0)"
        else {
            respond(on: connection, identifier: identifier, status: 400, runID: runID)
            return
        }
        let target = String(requestLine[1])
        guard let components = URLComponents(string: "http://127.0.0.1:\(callbackURL.port ?? 0)\(target)"),
              components.path == "/auth/callback",
              components.fragment == nil,
              let result = components.url
        else {
            respond(on: connection, identifier: identifier, status: 404, runID: runID)
            return
        }
        connection.send(content: httpResponse(status: 200), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID else { connection.cancel(); return }
                connection.cancel()
                self.connections.removeValue(forKey: identifier)
                self.requestBuffers.removeValue(forKey: identifier)
                self.finish(result: result, runID: runID)
            }
        })
    }

    private func respond(on connection: NWConnection, identifier: ObjectIdentifier, status: Int, runID: UUID) {
        connection.send(content: httpResponse(status: status), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID else { connection.cancel(); return }
                connection.cancel()
                self.connections.removeValue(forKey: identifier)
                self.requestBuffers.removeValue(forKey: identifier)
            }
        })
    }

    private func httpResponse(status: Int) -> Data {
        let body = status == 200
            ? "<!doctype html><meta charset=utf-8><title>Sign-in complete</title><p>You can close this window and return to Imrse.</p>"
            : "<!doctype html><meta charset=utf-8><title>Sign-in</title><p>This sign-in link is invalid. Return to Imrse and try again.</p>"
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bodyData
    }

    private static func isOfficialAuthorizationURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["openrouter.ai", "huggingface.co"].contains(host),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    private static func isOfficialDeviceVerificationURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "github.com"
            && components.path == "/login/device"
            && components.user == nil
            && components.password == nil
            && components.port == nil
            && components.query == nil
            && components.fragment == nil
    }

    private func finish(result: URL, runID: UUID) {
        finish(with: .success(result), runID: runID)
    }

    private func finish(error: OfficialAccountSignInCoordinatorError, runID: UUID) {
        finish(with: .failure(error), runID: runID)
    }

    private func finish(with result: Result<URL, any Error>, runID: UUID) {
        guard self.runID == runID else { return }
        let readiness = readiness
        let callback = callback
        self.readiness = nil
        self.callback = nil
        readyTimeoutTask?.cancel()
        callbackTimeoutTask?.cancel()
        readyTimeoutTask = nil
        callbackTimeoutTask = nil
        listener?.cancel()
        listener = nil
        self.runID = nil
        callbackURL = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        requestBuffers.removeAll()
        readiness?.resume(with: result)
        callback?.resume(with: result)
    }
}

private enum OfficialAccountSignInCoordinatorError: Error, Sendable {
    case alreadyActive
    case listenerUnavailable
    case invalidAuthorizationURL
    case browserUnavailable
    case timedOut
    case cancelled
}
