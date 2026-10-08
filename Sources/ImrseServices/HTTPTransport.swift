import Foundation
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPExchange: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, any Error>
    private let cancelBody: @Sendable () -> Void

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, any Error>,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        cancelBody = cancel
    }

    public func cancel() { cancelBody() }
}

public protocol StreamingHTTPTransport: Sendable {
    func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange
}

public struct URLSessionHTTPTransport: StreamingHTTPTransport, Sendable {
    public init() {}

    public func execute(_ request: URLRequest, localOnly: Bool) async throws -> HTTPExchange {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        if localOnly {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0,
                "ProxyAutoDiscoveryEnable": 0
            ]
        }
        let body = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(2_048))
        let driver = URLSessionStreamDriver(configuration: configuration, body: body.continuation)
        body.continuation.onTermination = { [weak driver] termination in
            if case .cancelled = termination { driver?.cancel() }
        }
        let head = try await driver.start(request)
        return HTTPExchange(
            statusCode: head.statusCode,
            headers: head.headers,
            body: body.stream,
            cancel: { driver.cancel() }
        )
    }
}

private struct HTTPResponseHead: Sendable {
    let statusCode: Int
    let headers: [String: String]
}

final class URLSessionStreamDriver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var body: AsyncThrowingStream<Data, any Error>.Continuation?
    private var response: CheckedContinuation<HTTPResponseHead, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(configuration: URLSessionConfiguration, body: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.configuration = configuration
        self.body = body
    }

    fileprivate func start(_ request: URLRequest) async throws -> HTTPResponseHead {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)

                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    task.cancel()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.session = session
                self.task = task
                response = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        terminate(with: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            terminate(with: ImrseError.server)
            return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let name = item.key as? String else { return }
            result[name.lowercased()] = String(describing: item.value)
        }

        lock.lock()
        let continuation = self.response
        self.response = nil
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled, let continuation else {
            completionHandler(.cancel)
            return
        }
        continuation.resume(returning: HTTPResponseHead(statusCode: response.statusCode, headers: headers))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let continuation = body
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled, let continuation else { return }

        let chunkSize = 8_192
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            switch continuation.yield(chunk) {
            case .enqueued:
                offset = end
            case .dropped:
                terminate(with: ImrseError.interruptedStream)
                return
            case .terminated:
                cancel()
                return
            @unknown default:
                terminate(with: ImrseError.network)
                return
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let response = self.response
        self.response = nil
        let body = self.body
        self.body = nil
        let session = self.session
        self.session = nil
        self.task = nil
        let wasCancelled = cancelled
        lock.unlock()

        if let response {
            response.resume(throwing: error ?? (wasCancelled ? CancellationError() : ImrseError.server))
        }
        if let error {
            body?.finish(throwing: error)
        } else if wasCancelled {
            body?.finish(throwing: CancellationError())
        } else {
            body?.finish()
        }
        session?.finishTasksAndInvalidate()
    }

    private func terminate(with error: any Error) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let response = self.response
        self.response = nil
        let body = self.body
        self.body = nil
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()

        response?.resume(throwing: error)
        body?.finish(throwing: error)
        task?.cancel()
        session?.invalidateAndCancel()
    }
}
