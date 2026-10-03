import Foundation
import XCTest
import ImrseCore
@testable import ImrseServices
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class LocalHTTPIntegrationTests: XCTestCase {
    func testURLSessionStreamsFirstDeltaBeforeResponseCompletes() async throws {
        let first = "data: {\"choices\":[{\"delta\":{\"content\":\"first\"},\"finish_reason\":null}]}\n\n"
        let last = "data: {\"choices\":[{\"delta\":{\"content\":\" second\"},\"finish_reason\":\"stop\"}]}\n\n"
        let server = try LocalHTTPServer(bodyParts: [Data(first.utf8), Data(last.utf8)], pausesAfterFirstWrite: true)
        defer { server.stop() }
        let provider = OpenAICompatibleProvider(credentials: NoCredentials())
        let stream = try await provider.stream(request(port: server.port))
        let firstDelta = TestSignal()
        let consumer = Task { () -> ProviderResult in
            var output = ""
            do {
                for try await delta in stream {
                    output += delta
                    firstDelta.signal()
                }
                return ProviderResult(output: output)
            } catch {
                return ProviderResult(output: output, error: error as? ImrseError, cancelled: error is CancellationError)
            }
        }

        let arrivedWhileServerPaused = await firstDelta.wait(timeout: 2)
        server.releaseAfterFirstWrite()
        let result = await consumer.value
        XCTAssertTrue(arrivedWhileServerPaused)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "first second")
    }

    func testCancellingLocalStreamCancelsTheHTTPRequest() async throws {
        let first = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
        let last = "data: {\"choices\":[{\"delta\":{\"content\":\"unneeded\"},\"finish_reason\":\"stop\"}]}\n\n"
        let server = try LocalHTTPServer(
            bodyParts: [Data(first.utf8), Data(last.utf8)],
            pausesAfterFirstWrite: true,
            observesCancellationAfterFirstWrite: true
        )
        defer {
            server.releaseAfterFirstWrite()
            server.stop()
        }
        let provider = OpenAICompatibleProvider(credentials: NoCredentials())
        let stream = try await provider.stream(request(port: server.port))
        let firstDelta = TestSignal()
        let consumer = Task { () -> ProviderResult in
            var output = ""
            do {
                for try await delta in stream {
                    output += delta
                    firstDelta.signal()
                }
                return ProviderResult(output: output, cancelled: Task.isCancelled)
            } catch {
                return ProviderResult(output: output, error: error as? ImrseError, cancelled: error is CancellationError)
            }
        }

        let started = await firstDelta.wait(timeout: 2)
        consumer.cancel()
        let result = await consumer.value
        let cancellationObserved = await server.waitForCancellation(timeout: 2)
        XCTAssertTrue(started)
        XCTAssertTrue(result.cancelled || result.error == .cancelled)
        XCTAssertTrue(cancellationObserved)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testSuccessfulCompletionCancelsAnOpenHTTPResponse() async throws {
        let completion = "data: {\"choices\":[{\"delta\":{\"content\":\"complete\"},\"finish_reason\":\"stop\"}]}\n\n"
        let server = try LocalHTTPServer(
            bodyParts: [Data(completion.utf8), Data(repeating: 0x20, count: 1_024)],
            pausesAfterFirstWrite: true,
            observesCancellationAfterFirstWrite: true
        )
        defer {
            server.releaseAfterFirstWrite()
            server.stop()
        }
        let provider = OpenAICompatibleProvider(credentials: NoCredentials())

        let output = try await collect(provider, request: request(port: server.port))
        let cancellationObserved = await server.waitForCancellation(timeout: 2)
        XCTAssertEqual(output, "complete")
        XCTAssertTrue(cancellationObserved)
    }

    func testURLSessionNeverFollowsAProviderRedirect() async throws {
        let destination = try LocalHTTPServer(bodyParts: [Data("should not receive selected text".utf8)])
        defer { destination.stop() }
        let location = "http://127.0.0.1:\(destination.port)/v1/chat/completions"
        let redirect = try LocalHTTPServer(statusCode: 302, responseHeaders: ["Location": location], bodyParts: [])
        defer { redirect.stop() }
        let provider = OpenAICompatibleProvider(credentials: NoCredentials())

        await assertError(.invalidConfiguration) {
            _ = try await collect(provider, request: request(port: redirect.port))
        }
        XCTAssertEqual(redirect.requestCount, 1)
        let destinationReceivedRequest = await destination.waitForRequest(timeout: 0.2)
        XCTAssertFalse(destinationReceivedRequest)
        XCTAssertEqual(destination.requestCount, 0)
    }

    private func request(port: UInt16) -> TransformationRequest {
        TransformationRequest(
            text: "selected",
            instruction: "rewrite",
            provider: ProviderConfiguration(
                id: "local",
                name: "Local",
                kind: .compatible,
                endpoint: URL(string: "http://127.0.0.1:\(port)/v1")!,
                model: "local-model",
                requiresCredential: false
            ),
            localOnly: true
        )
    }
}

private struct ProviderResult: Sendable {
    let output: String
    var error: ImrseError?
    var cancelled = false
}

private final class TestSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() { semaphore.signal() }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}

private actor NoCredentials: CredentialStore {
    func credential(for providerID: String) async throws -> String? { nil }
    func setCredential(_ value: String?, for providerID: String) async throws {}
}

private final class LocalHTTPServer: @unchecked Sendable {
    private let descriptor: Int32
    private let responseParts: [Data]
    private let pausesAfterFirstWrite: Bool
    private let observesCancellationAfterFirstWrite: Bool
    private let lock = NSLock()
    private var stopped = false
    private var receivedRequests = 0
    private let requestReceived = TestSignal()
    private let clientCancellationObserved = TestSignal()
    private let continueWriting = DispatchSemaphore(value: 0)
    let port: UInt16

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests
    }

    init(
        statusCode: Int = 200,
        responseHeaders: [String: String] = ["Content-Type": "text/event-stream"],
        bodyParts: [Data],
        pausesAfterFirstWrite: Bool = false,
        observesCancellationAfterFirstWrite: Bool = false
    ) throws {
        self.pausesAfterFirstWrite = pausesAfterFirstWrite
        self.observesCancellationAfterFirstWrite = observesCancellationAfterFirstWrite
        let bodySize = bodyParts.reduce(0) { $0 + $1.count }
        let headers = responseHeaders
            .map { "\($0.key): \($0.value)\r\n" }
            .sorted()
            .joined()
        let responseHead = Data("HTTP/1.1 \(statusCode) \(statusText(statusCode))\r\n\(headers)Content-Length: \(bodySize)\r\nConnection: close\r\n\r\n".utf8)
        if let firstBodyPart = bodyParts.first {
            var firstResponsePart = responseHead
            firstResponsePart.append(firstBodyPart)
            responseParts = [firstResponsePart] + Array(bodyParts.dropFirst())
        } else {
            responseParts = [responseHead]
        }

        let socketDescriptor = socket(AF_INET, streamSocketType(), 0)
        guard socketDescriptor >= 0 else { throw socketError() }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(socketDescriptor, 1) == 0 else {
            let error = socketError()
            closeSocket(socketDescriptor)
            throw error
        }
        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &boundAddress) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &addressLength)
            }
        }
        guard addressResult == 0 else {
            let error = socketError()
            closeSocket(socketDescriptor)
            throw error
        }
        descriptor = socketDescriptor
        port = UInt16(bigEndian: boundAddress.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptOneRequest() }
    }

    func waitForRequest(timeout: TimeInterval) async -> Bool { await requestReceived.wait(timeout: timeout) }
    func waitForCancellation(timeout: TimeInterval) async -> Bool { await clientCancellationObserved.wait(timeout: timeout) }

    func releaseAfterFirstWrite() { continueWriting.signal() }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        continueWriting.signal()
        wakeListener()
        _ = shutdown(descriptor, shutdownBoth())
        closeSocket(descriptor)
    }

    private func acceptOneRequest() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        lock.lock()
        receivedRequests += 1
        lock.unlock()
        requestReceived.signal()
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        guard receiveRequest(client) else {
            closeSocket(client)
            return
        }

        for (index, part) in responseParts.enumerated() {
            guard sendAll(part, to: client) else { break }
            if pausesAfterFirstWrite && index == 0 {
                if observesCancellationAfterFirstWrite, waitForClientCancellation(client) {
                    clientCancellationObserved.signal()
                    break
                }
                _ = continueWriting.wait(timeout: .now() + 10)
            }
        }
        closeSocket(client)
    }

    private func receiveRequest(_ client: Int32) -> Bool {
        var request = Data()
        var expectedSize: Int?
        while request.count < 2_097_152 {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let received = bytes.withUnsafeMutableBytes { Int(recv(client, $0.baseAddress, $0.count, 0)) }
            guard received > 0 else { return false }
            request.append(contentsOf: bytes.prefix(received))
            if expectedSize == nil,
               let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(decoding: request[..<headerEnd.upperBound], as: UTF8.self)
                let length = headerText.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    guard line.lowercased().hasPrefix("content-length:") else { return nil }
                    return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                }.first ?? 0
                expectedSize = headerEnd.upperBound + length
            }
            if let expectedSize, request.count >= expectedSize { return true }
        }
        return false
    }

    private func sendAll(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let sent = send(client, baseAddress.advanced(by: offset), bytes.count - offset, socketSendFlags())
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }

    private func waitForClientCancellation(_ client: Int32) -> Bool {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let timeoutResult = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        guard timeoutResult == 0 else { return false }
        var byte: UInt8 = 0
        let result = withUnsafeMutablePointer(to: &byte) {
            recv(client, $0, 1, Int32(MSG_PEEK))
        }
        return result == 0 || (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    private func wakeListener() {
        let wake = socket(AF_INET, streamSocketType(), 0)
        guard wake >= 0 else { return }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        closeSocket(wake)
    }

    deinit { stop() }
}

private func streamSocketType() -> Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

private func socketSendFlags() -> Int32 {
    #if canImport(Darwin)
    return 0
    #else
    return Int32(MSG_NOSIGNAL)
    #endif
}

private func shutdownBoth() -> Int32 {
    #if canImport(Darwin)
    return SHUT_RDWR
    #else
    return Int32(SHUT_RDWR)
    #endif
}

private func closeSocket(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #else
    _ = Glibc.close(descriptor)
    #endif
}

private func socketError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func statusText(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 302: "Found"
    default: "Response"
    }
}

private func collect(_ provider: OpenAICompatibleProvider, request: TransformationRequest) async throws -> String {
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
