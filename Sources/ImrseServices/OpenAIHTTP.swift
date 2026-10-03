import Foundation
import ImrseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OpenAIHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

enum OpenAIHTTP {
    static let maximumResponseBytes = 1_048_576
    private static let maximumErrorResponseBytes = 65_536

    static func send(
        _ request: URLRequest,
        using transport: any StreamingHTTPTransport,
        maximumResponseBytes: Int = Self.maximumResponseBytes,
        localOnly: Bool = false
    ) async throws -> OpenAIHTTPResponse {
        let exchange: HTTPExchange
        do {
            exchange = try await transport.execute(request, localOnly: localOnly)
        } catch is CancellationError {
            throw OpenAIAccountClientError.cancelled
        } catch {
            throw OpenAIAccountClientError.networkFailure
        }
        defer { exchange.cancel() }
        guard (200..<300).contains(exchange.statusCode) else {
            let code: String?
            do { code = try await errorCode(from: exchange.body) }
            catch is CancellationError { throw OpenAIAccountClientError.cancelled }
            catch { code = nil }
            if exchange.statusCode == 400, code == "invalid_grant" {
                throw OpenAIAccountClientError.invalidGrant
            }
            if exchange.statusCode == 400, code == "invalid_client" {
                throw OpenAIAccountClientError.invalidClientConfiguration
            }
            throw OpenAIAccountClientError.requestFailed(exchange.statusCode)
        }

        var body = Data()
        do {
            for try await chunk in exchange.body {
                try Task.checkCancellation()
                guard chunk.count <= maximumResponseBytes - body.count else {
                    throw OpenAIAccountClientError.responseTooLarge
                }
                body.append(chunk)
            }
        } catch is CancellationError {
            throw OpenAIAccountClientError.cancelled
        } catch let error as OpenAIAccountClientError {
            throw error
        } catch {
            throw OpenAIAccountClientError.networkFailure
        }
        return OpenAIHTTPResponse(statusCode: exchange.statusCode, headers: exchange.headers, body: body)
    }

    private static func errorCode(from stream: AsyncThrowingStream<Data, any Error>) async throws -> String? {
        var body = Data()
        for try await chunk in stream {
            try Task.checkCancellation()
            guard chunk.count <= maximumErrorResponseBytes - body.count else { return nil }
            body.append(chunk)
        }
        guard let response = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let code = response["error"] as? String ?? (response["error"] as? [String: Any])?["code"] as? String
        guard let code, code.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return code
    }

    static func formRequest(
        url: URL,
        values: [(String, String)],
        timeout: TimeInterval = 30
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.0, value: $0.1) }
        let form = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "%20", with: "+")
        request.httpBody = Data(form.utf8)
        return request
    }

    static func getRequest(url: URL, bearerToken: String? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
