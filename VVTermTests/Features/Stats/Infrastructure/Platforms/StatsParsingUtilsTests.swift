import XCTest
@testable import VVTerm

final class StatsParsingUtilsTests: XCTestCase {
    func testCalculateNetworkSpeedReturnsZeroWithoutPreviousTimestamp() {
        let now = Date()

        let speed = StatsParsingUtils.calculateNetworkSpeed(
            currentRx: 1_000,
            currentTx: 2_000,
            prevRx: 100,
            prevTx: 200,
            prevTimestamp: nil,
            now: now
        )

        XCTAssertEqual(speed.rxSpeed, 0)
        XCTAssertEqual(speed.txSpeed, 0)
    }

    func testCalculateNetworkSpeedUsesElapsedSeconds() {
        let now = Date()
        let previous = now.addingTimeInterval(-2)

        let speed = StatsParsingUtils.calculateNetworkSpeed(
            currentRx: 3_000,
            currentTx: 5_000,
            prevRx: 1_000,
            prevTx: 1_000,
            prevTimestamp: previous,
            now: now
        )

        XCTAssertEqual(speed.rxSpeed, 1_000)
        XCTAssertEqual(speed.txSpeed, 2_000)
    }

    func testCalculateNetworkSpeedTreatsCounterResetAsZeroDelta() {
        let now = Date()
        let previous = now.addingTimeInterval(-2)

        let speed = StatsParsingUtils.calculateNetworkSpeed(
            currentRx: 500,
            currentTx: 600,
            prevRx: 1_000,
            prevTx: 1_200,
            prevTimestamp: previous,
            now: now
        )

        XCTAssertEqual(speed.rxSpeed, 0)
        XCTAssertEqual(speed.txSpeed, 0)
    }

    func testParseLoadAverageStripsBracesAndWhitespace() {
        let parsed = StatsParsingUtils.parseLoadAverage(" { 1.25 2.50 3.75 } ")

        XCTAssertEqual(parsed.0, 1.25, accuracy: 0.001)
        XCTAssertEqual(parsed.1, 2.50, accuracy: 0.001)
        XCTAssertEqual(parsed.2, 3.75, accuracy: 0.001)
    }
}
