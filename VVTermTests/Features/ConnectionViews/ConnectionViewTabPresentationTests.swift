import XCTest
@testable import VVTerm

final class ConnectionViewTabPresentationTests: XCTestCase {
    func testTabPresentationPreservesLocalizedKeysAndSymbols() {
        XCTAssertEqual(ConnectionViewTabID.stats.localizedKey, "Stats")
        XCTAssertEqual(ConnectionViewTabID.stats.icon, "chart.bar.xaxis")
        XCTAssertEqual(ConnectionViewTabID.terminal.localizedKey, "Terminal")
        XCTAssertEqual(ConnectionViewTabID.terminal.icon, "terminal")
        XCTAssertEqual(ConnectionViewTabID.files.localizedKey, "Files")
        XCTAssertEqual(ConnectionViewTabID.files.icon, "folder")
    }
}
