import Foundation
import XCTest
@testable import ImrseMac

final class KeychainCredentialStoreTests: XCTestCase, @unchecked Sendable {
    func testIsolatedCredentialCanBeCreatedUpdatedAndRemoved() async throws {
        let store = KeychainCredentialStore(service: "org.imrse.tests.\(UUID().uuidString)")
        let providerID = "fixture"
        do {
            let initial = try await store.credential(for: providerID)
            XCTAssertNil(initial)
            try await store.setCredential("first-test-fixture", for: providerID)
            let first = try await store.credential(for: providerID)
            XCTAssertEqual(first, "first-test-fixture")
            try await store.setCredential("updated-test-fixture", for: providerID)
            let updated = try await store.credential(for: providerID)
            XCTAssertEqual(updated, "updated-test-fixture")
            try await store.setCredential(nil, for: providerID)
            let removed = try await store.credential(for: providerID)
            XCTAssertNil(removed)
        } catch {
            try? await store.setCredential(nil, for: providerID)
            throw error
        }
    }
}
