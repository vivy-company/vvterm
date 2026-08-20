import XCTest
@testable import VVTerm

final class ServerEnvironmentTests: XCTestCase {
    func testBuiltInEnvironmentDisplayUsesLocalizedBuiltIns() {
        XCTAssertEqual(ServerEnvironment.production.displayName, String(localized: "Production"))
        XCTAssertEqual(ServerEnvironment.staging.displayShortName, String(localized: "Stag"))
        XCTAssertEqual(ServerEnvironment.development.displayShortName, String(localized: "Dev"))
    }

    func testCustomEnvironmentDisplayUsesRawValues() {
        let environment = ServerEnvironment(name: "QA", shortName: "QA", colorHex: "#123456")

        XCTAssertEqual(environment.displayName, "QA")
        XCTAssertEqual(environment.displayShortName, "QA")
    }
}
