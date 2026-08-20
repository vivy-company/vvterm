import XCTest
@testable import VVTerm

final class WelcomeFeatureTests: XCTestCase {
    func testSemanticIdentitiesAreStableAndUnique() {
        XCTAssertEqual(
            WelcomeFeatureID.allCases.map(\.rawValue),
            [
                "ssh_terminal",
                "sftp_files",
                "server_stats",
                "companion_platform",
                "icloud_sync",
                "session_persistence",
                "secure_storage",
                "voice_commands"
            ]
        )
        XCTAssertEqual(
            Set(WelcomeFeatureID.allCases.map(\.id)).count,
            WelcomeFeatureID.allCases.count
        )
    }

    func testSemanticIdentitiesRoundTripThroughCodable() throws {
        let encoded = try JSONEncoder().encode(WelcomeFeatureID.allCases)
        let decoded = try JSONDecoder().decode([WelcomeFeatureID].self, from: encoded)

        XCTAssertEqual(decoded, WelcomeFeatureID.allCases)
    }
}
