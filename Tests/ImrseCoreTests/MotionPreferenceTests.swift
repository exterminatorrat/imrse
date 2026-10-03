import Foundation
import ImrseCore
import XCTest

final class MotionPreferenceTests: XCTestCase {
    func testMotionPreferencesPreserveCodableRawValues() throws {
        let preferences: [(String, MotionPreference)] = [
            ("instant", .instant),
            ("quick", .quick),
            ("smooth", .smooth),
            ("balanced", .balanced),
            ("slow", .slow)
        ]

        for (rawValue, preference) in preferences {
            let serializedValue = Data("\"\(rawValue)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(MotionPreference.self, from: serializedValue), preference)
            XCTAssertEqual(try JSONEncoder().encode(preference), serializedValue)
        }
    }

    func testLegacyConfigurationMotionPreferencesDecodeWithoutMigration() throws {
        for (rawValue, preference) in [("instant", MotionPreference.instant), ("smooth", .smooth)] {
            let data = Data("""
            {
              "version": 1,
              "providers": [],
              "selectedProviderID": null,
              "invocation": {
                "doubleControlEnabled": true,
                "doubleControlInterval": 0.32,
                "shortcut": null
              },
              "motion": "\(rawValue)",
              "clipboardFallbackEnabled": false
            }
            """.utf8)

            let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
            XCTAssertEqual(configuration.motion, preference)
        }
    }
}
