import XCTest
@testable import VVTerm

final class TmuxDomainTests: XCTestCase {
    func testStartupBehaviorConfigurationCasesPreserveRawValueOrder() {
        XCTAssertEqual(TmuxStartupBehavior.configCases, TmuxStartupBehavior.allCases)
        XCTAssertEqual(
            TmuxStartupBehavior.configCases.map(\.rawValue),
            ["vvtermManaged", "askEveryTime", "skipTmux"]
        )
    }

    func testStatusTmuxIndicationRules() {
        XCTAssertTrue(TmuxStatus.foreground.indicatesTmux)
        XCTAssertTrue(TmuxStatus.background.indicatesTmux)
        XCTAssertTrue(TmuxStatus.unknown.indicatesTmux)
        XCTAssertFalse(TmuxStatus.off.indicatesTmux)
        XCTAssertFalse(TmuxStatus.missing.indicatesTmux)
        XCTAssertFalse(TmuxStatus.installing.indicatesTmux)
    }
}
