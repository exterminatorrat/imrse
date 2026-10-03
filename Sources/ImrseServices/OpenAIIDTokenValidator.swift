import Foundation
#if canImport(Security)
import Security
#endif

struct OpenAIVerifiedIdentity: Sendable {
    let subject: String
    let email: String?
}

enum OpenAIIDTokenValidator {
    static func validate(
        _ token: String,
        expectedClientID: String,
        expectedNonce: String,
        jwks: Data,
        now: Date
    ) throws -> OpenAIVerifiedIdentity {
        guard token.utf8.count <= 65_536,
              expectedClientID.utf8.count <= 256,
              expectedNonce.utf8.count <= 256,
              jwks.count <= 262_144
        else { throw OpenAIAccountClientError.invalidIdentityToken }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let payloadData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2]))
        else { throw OpenAIAccountClientError.invalidIdentityToken }

        let header: Header
        let keySet: KeySet
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
            keySet = try JSONDecoder().decode(KeySet.self, from: jwks)
        } catch {
            throw OpenAIAccountClientError.invalidIdentityToken
        }
        guard header.algorithm == "RS256", header.criticalHeaders?.isEmpty ?? true,
              !header.keyID.isEmpty,
              keySet.keys.count <= 64
        else { throw OpenAIAccountClientError.invalidIdentityToken }

        let matches = keySet.keys.filter { key in
              key.keyID == header.keyID && key.type == "RSA" && (key.use == nil || key.use == "sig")
                && (key.algorithm == nil || key.algorithm == "RS256")
        }
        guard matches.count == 1,
              let modulus = Data(base64URL: matches[0].modulus),
              let exponent = Data(base64URL: matches[0].exponent),
              (256...512).contains(modulus.count),
              (1...8).contains(exponent.count)
        else { throw OpenAIAccountClientError.invalidIdentityToken }

#if canImport(Security)
        guard verifySignature(
            signature,
            input: Data("\(parts[0]).\(parts[1])".utf8),
            modulus: modulus,
            exponent: exponent
        ) else { throw OpenAIAccountClientError.invalidIdentityToken }

        let claims: Claims
        do { claims = try JSONDecoder().decode(Claims.self, from: payloadData) }
        catch { throw OpenAIAccountClientError.invalidIdentityToken }
        guard claims.issuer == "https://auth.openai.com",
              claims.audience.contains(expectedClientID),
              claims.expiry.isFinite,
              claims.expiry > now.timeIntervalSince1970 - 5,
              claims.nonce == expectedNonce,
              !claims.subject.isEmpty,
              claims.subject.utf8.count <= 1_024,
              !claims.subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              claims.hasValidAuthorizedParty(for: expectedClientID)
        else { throw OpenAIAccountClientError.invalidIdentityToken }

        let email: String?
        if let value = claims.email,
           value.utf8.count <= 320,
           !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        {
            email = value
        } else {
            email = nil
        }
        return OpenAIVerifiedIdentity(subject: claims.subject, email: email)
#else
        _ = payloadData
        _ = signature
        _ = modulus
        _ = exponent
        throw OpenAIAccountClientError.cryptographyUnavailable
#endif
    }

#if canImport(Security)
    private static func verifySignature(_ signature: Data, input: Data, modulus: Data, exponent: Data) -> Bool {
        let content = integer(modulus) + integer(exponent)
        let der = sequence(content)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error),
              SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256)
        else { return false }
        return SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            input as CFData,
            signature as CFData,
            &error
        )
    }

    private static func sequence(_ content: Data) -> Data {
        return Data([0x30]) + length(content.count) + content
    }

    private static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value.append(0) }
        if value[0] >= 0x80 { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }

    private static func length(_ length: Int) -> Data {
        guard length >= 128 else { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
#endif
}

private struct Header: Decodable {
    let algorithm: String
    let keyID: String
    let criticalHeaders: [String]?

    enum CodingKeys: String, CodingKey {
        case algorithm = "alg"
        case keyID = "kid"
        case criticalHeaders = "crit"
    }
}

private struct Claims: Decodable {
    let issuer: String
    let subject: String
    let audience: Audience
    let expiry: TimeInterval
    let nonce: String
    let email: String?
    let authorizedParty: String?

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case subject = "sub"
        case audience = "aud"
        case expiry = "exp"
        case nonce
        case email
        case authorizedParty = "azp"
    }

    func hasValidAuthorizedParty(for clientID: String) -> Bool {
        if audience.count > 1 { return authorizedParty == clientID }
        return authorizedParty.map { $0 == clientID } ?? true
    }
}

private enum Audience: Decodable {
    case one(String)
    case many([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .one(value)
        } else {
            self = .many(try container.decode([String].self))
        }
    }

    func contains(_ clientID: String) -> Bool {
        switch self {
        case .one(let value): value == clientID
        case .many(let values): values.contains(clientID)
        }
    }

    var count: Int {
        switch self {
        case .one: 1
        case .many(let values): values.count
        }
    }
}

private struct KeySet: Decodable {
    let keys: [Key]
}

private struct Key: Decodable {
    let type: String
    let keyID: String
    let use: String?
    let algorithm: String?
    let modulus: String
    let exponent: String

    enum CodingKeys: String, CodingKey {
        case type = "kty"
        case keyID = "kid"
        case use
        case algorithm = "alg"
        case modulus = "n"
        case exponent = "e"
    }
}

private extension Data {
    init?(base64URL: String) {
        var encoded = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.utf8.count % 4
        if remainder != 0 { encoded.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: encoded)
    }
}
