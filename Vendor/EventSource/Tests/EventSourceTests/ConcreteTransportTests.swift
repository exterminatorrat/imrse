#if swift(>=6.1) && !canImport(FoundationNetworking)
import EventSource
import Foundation
import Testing

private enum CallbackObservation: Equatable, Sendable {
    case open
    case message(id: String?, data: String)
    case error(isNil: Bool)
    case closedFromOpen
    case closedFromMessage
    case closedFromError
}

private actor ResponseGate {
    private let requestStream: AsyncStream<Void>
    private let requestContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private var requestCount = 0
    private var responseReleased = false

    init() {
        let (requestStream, requestContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.requestStream = requestStream
        self.requestContinuation = requestContinuation
        self.releaseStream = releaseStream
        self.releaseContinuation = releaseContinuation
    }

    func recordRequest() -> Int {
        requestCount += 1
        if requestCount == 1 {
            requestContinuation.yield(())
            requestContinuation.finish()
        }
        return requestCount
    }

    func waitForFirstRequest() async -> Bool {
        if requestCount > 0 {
            return true
        }
        var iterator = requestStream.makeAsyncIterator()
        return await iterator.next() != nil
    }

    func waitForResponseRelease() async {
        guard !responseReleased else { return }
        var iterator = releaseStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseResponse() {
        guard !responseReleased else { return }
        responseReleased = true
        releaseContinuation.yield(())
        releaseContinuation.finish()
    }

    func count() -> Int {
        requestCount
    }
}

private func makeResponse(
    for url: URL,
    body: String,
    statusCode: Int = 200,
    contentType: String = "text/event-stream"
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": contentType]
    )!
    return (response, Data(body.utf8))
}

private func makeEventSource(for url: URL) -> EventSource {
    var request = URLRequest(url: url)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return EventSource(request: request, configuration: configuration)
}

private func installResponse(for url: URL, body: String, gate: ResponseGate) async {
    await MockURLProtocol.setHandler { request in
        #expect(request.url == url)
        let requestNumber = await gate.recordRequest()
        if requestNumber == 1 {
            await gate.waitForResponseRelease()
            return makeResponse(for: url, body: body)
        }
        return makeResponse(
            for: url,
            body: "",
            statusCode: 500,
            contentType: "text/plain"
        )
    }
}

private func withTransportCleanup(
    eventSource: EventSource,
    gate: ResponseGate,
    callbackContinuation: AsyncStream<CallbackObservation>.Continuation,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        await eventSource.close()
        await gate.releaseResponse()
        callbackContinuation.finish()
        throw error
    }

    await eventSource.close()
    await gate.releaseResponse()
    callbackContinuation.finish()
}

extension IntegrationTests {
    @Suite("Concrete URLSession transport")
    struct ConcreteTransportTests {
        @Test(
            "URLSession.AsyncBytes delivers public callbacks in order",
            .mockURLSession,
            .timeLimit(.minutes(1))
        )
        func callbackDeliveryAndOrder() async throws {
            let url = URL(string: "https://example.com/events")!
            let body = "retry: 1\n\nid: one\ndata: first\n\nid: two\ndata: second\n\n"
            let gate = ResponseGate()
            let (callbackStream, callbackContinuation) = AsyncStream<CallbackObservation>.makeStream()
            await installResponse(for: url, body: body, gate: gate)

            let eventSource = makeEventSource(for: url)
            try await withTransportCleanup(
                eventSource: eventSource,
                gate: gate,
                callbackContinuation: callbackContinuation
            ) {
                try await confirmation(
                    "Delivers open, messages, then stream-close error",
                    expectedCount: 4
                ) { confirm in
                    var iterator = callbackStream.makeAsyncIterator()
                    eventSource.onOpen = {
                        callbackContinuation.yield(.open)
                        confirm()
                    }
                    eventSource.onMessage = { event in
                        callbackContinuation.yield(.message(id: event.id, data: event.data))
                        confirm()
                    }
                    eventSource.onError = { [weak eventSource] error in
                        callbackContinuation.yield(.error(isNil: error == nil))
                        confirm()
                        if error == nil {
                            await eventSource?.close()
                            callbackContinuation.yield(.closedFromError)
                        }
                    }

                    try #require(await gate.waitForFirstRequest())
                    _ = await eventSource.readyState
                    await gate.releaseResponse()

                    let open = try #require(await iterator.next())
                    let first = try #require(await iterator.next())
                    let second = try #require(await iterator.next())
                    let error = try #require(await iterator.next())
                    let closed = try #require(await iterator.next())

                    #expect(
                        [open, first, second, error, closed]
                            == [
                                .open,
                                .message(id: "one", data: "first"),
                                .message(id: "two", data: "second"),
                                .error(isNil: true),
                                .closedFromError,
                            ]
                    )
                    try await Task.sleep(for: .milliseconds(250))
                }
            }

            #expect(await gate.count() == 1)
        }

        @Test(
            "Closing in the first message callback stops later data and reconnection",
            .mockURLSession,
            .timeLimit(.minutes(1))
        )
        func closeFromFirstMessageStopsStream() async throws {
            let url = URL(string: "https://example.com/events")!
            let body = "retry: 1\n\nid: one\ndata: first\n\nid: two\ndata: second\n\n"
            let gate = ResponseGate()
            let (callbackStream, callbackContinuation) = AsyncStream<CallbackObservation>.makeStream()
            await installResponse(for: url, body: body, gate: gate)

            let eventSource = makeEventSource(for: url)
            try await withTransportCleanup(
                eventSource: eventSource,
                gate: gate,
                callbackContinuation: callbackContinuation
            ) {
                try await confirmation(
                    "Only open and the first message are delivered",
                    expectedCount: 2
                ) { confirm in
                    var iterator = callbackStream.makeAsyncIterator()
                    eventSource.onOpen = {
                        callbackContinuation.yield(.open)
                        confirm()
                    }
                    eventSource.onMessage = { [weak eventSource] event in
                        callbackContinuation.yield(.message(id: event.id, data: event.data))
                        confirm()
                        if event.data == "first" {
                            await eventSource?.close()
                            callbackContinuation.yield(.closedFromMessage)
                        }
                    }
                    eventSource.onError = { error in
                        callbackContinuation.yield(.error(isNil: error == nil))
                        confirm()
                    }

                    try #require(await gate.waitForFirstRequest())
                    _ = await eventSource.readyState
                    await gate.releaseResponse()

                    let open = try #require(await iterator.next())
                    let first = try #require(await iterator.next())
                    let closed = try #require(await iterator.next())

                    #expect(
                        [open, first, closed]
                            == [
                                .open,
                                .message(id: "one", data: "first"),
                                .closedFromMessage,
                            ]
                    )
                    try await Task.sleep(for: .milliseconds(250))
                }
            }

            #expect(await gate.count() == 1)
        }

        @Test(
            "Closing from open before byte consumption suppresses late callbacks",
            .mockURLSession,
            .timeLimit(.minutes(1))
        )
        func closeFromOpenPreventsLateCallbacks() async throws {
            let url = URL(string: "https://example.com/events")!
            let body = "retry: 1\n\nid: one\ndata: late first\n\nid: two\ndata: late second\n\n"
            let gate = ResponseGate()
            let (callbackStream, callbackContinuation) = AsyncStream<CallbackObservation>.makeStream()
            await installResponse(for: url, body: body, gate: gate)

            let eventSource = makeEventSource(for: url)
            try await withTransportCleanup(
                eventSource: eventSource,
                gate: gate,
                callbackContinuation: callbackContinuation
            ) {
                try await confirmation(
                    "Only open is delivered before close",
                    expectedCount: 1
                ) { confirm in
                    var iterator = callbackStream.makeAsyncIterator()
                    eventSource.onOpen = { [weak eventSource] in
                        callbackContinuation.yield(.open)
                        confirm()
                        await eventSource?.close()
                        callbackContinuation.yield(.closedFromOpen)
                    }
                    eventSource.onMessage = { event in
                        callbackContinuation.yield(.message(id: event.id, data: event.data))
                        confirm()
                    }
                    eventSource.onError = { error in
                        callbackContinuation.yield(.error(isNil: error == nil))
                        confirm()
                    }

                    try #require(await gate.waitForFirstRequest())
                    _ = await eventSource.readyState
                    await gate.releaseResponse()

                    let open = try #require(await iterator.next())
                    let closed = try #require(await iterator.next())
                    #expect([open, closed] == [.open, .closedFromOpen])
                    try await Task.sleep(for: .milliseconds(250))
                }
            }

            #expect(await gate.count() == 1)
        }
    }
}
#endif
