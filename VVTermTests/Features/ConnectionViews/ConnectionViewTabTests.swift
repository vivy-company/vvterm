import XCTest
@testable import VVTerm

final class ConnectionViewTabTests: XCTestCase {
    func testRawValuesPreserveStoredTabIdentifiers() throws {
        XCTAssertEqual(ConnectionViewTabID.stats.rawValue, "stats")
        XCTAssertEqual(ConnectionViewTabID.terminal.rawValue, "terminal")
        XCTAssertEqual(ConnectionViewTabID.files.rawValue, "files")

        let data = try JSONEncoder().encode(ConnectionViewTabID.allCases)
        let decoded = try JSONDecoder().decode([ConnectionViewTabID].self, from: data)

        XCTAssertEqual(decoded, ConnectionViewTabID.allCases)
    }

    func testConfigurationRepairsDuplicateOrderAndEmptyVisibility() {
        let configuration = ConnectionViewTabConfiguration(
            order: [.files, .files],
            visibleTabs: [],
            defaultTab: .terminal
        )

        XCTAssertEqual(configuration.order, [.files, .stats, .terminal])
        XCTAssertEqual(configuration.visibleTabs, Set(ConnectionViewTabID.allCases))
        XCTAssertEqual(configuration.defaultTab, .terminal)
    }

    func testConfigurationDecodingEnforcesInvariants() throws {
        let data = Data(
            #"{"order":["files","files"],"visibleTabs":[],"defaultTab":"terminal"}"#.utf8
        )

        let configuration = try JSONDecoder().decode(ConnectionViewTabConfiguration.self, from: data)

        XCTAssertEqual(configuration.order, [.files, .stats, .terminal])
        XCTAssertEqual(configuration.visibleTabs, Set(ConnectionViewTabID.allCases))
        XCTAssertEqual(configuration.effectiveDefaultTab, .terminal)
    }
}
