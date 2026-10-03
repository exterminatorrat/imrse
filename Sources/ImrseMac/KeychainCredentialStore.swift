#if os(macOS)
import Foundation
import ImrseCore
import Security

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "com.imrse.credentials") {
        self.service = service
    }

    public func credential(for providerID: String) async throws -> String? {
        let query = try itemQuery(for: providerID)
            .merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.operationFailed("read", status)
        }
        guard let data = item as? Data, let credential = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialStoreError.invalidCredentialData
        }
        return credential
    }

    public func setCredential(_ value: String?, for providerID: String) async throws {
        let query = try itemQuery(for: providerID)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound || status == errSecSuccess { return }
            throw KeychainCredentialStoreError.operationFailed("delete", status)
        }

        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialStoreError.operationFailed("add", addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.operationFailed("update", status)
        }
    }

    private func itemQuery(for providerID: String) throws -> [String: Any] {
        guard !service.isEmpty, !providerID.isEmpty else {
            throw KeychainCredentialStoreError.invalidItemIdentifier
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
    }
}

public enum KeychainCredentialStoreError: Error, LocalizedError, Sendable {
    case invalidItemIdentifier
    case invalidCredentialData
    case operationFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidItemIdentifier:
            "A Keychain service and provider identifier are required"
        case .invalidCredentialData:
            "The stored Keychain credential isn't valid UTF-8"
        case .operationFailed(let operation, let status):
            "Keychain \(operation) failed with OSStatus \(status)"
        }
    }
}
#endif
