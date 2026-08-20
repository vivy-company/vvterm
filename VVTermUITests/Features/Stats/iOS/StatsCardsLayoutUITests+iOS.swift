#if os(iOS)
import UIKit
import XCTest

final class StatsCardsLayoutUITests: XCTestCase {
    private var app: XCUIApplication!
    private var layoutConfiguration: LayoutConfiguration!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app = nil
        layoutConfiguration = nil
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDetailedCardsRemainContainedAcrossWideNarrowAndWideTransitions() throws {
        layoutConfiguration = .detailed
        launch()
        try assertExpectedColumnsAndContainment()

        try rotate(to: .landscapeLeft)
        try assertExpectedColumnsAndContainment()

        try rotate(to: .portrait)
        try assertExpectedColumnsAndContainment()

        try rotate(to: .landscapeRight)
        try assertExpectedColumnsAndContainment()
    }

    @MainActor
    func testCompactCardsRemainContainedAcrossWideNarrowAndWideTransitions() throws {
        layoutConfiguration = .compact
        launch(extraArguments: ["--vvterm-ui-test-stats-cards-compact"])
        try assertExpectedColumnsAndContainment()

        try rotate(to: .landscapeLeft)
        try assertExpectedColumnsAndContainment()

        try rotate(to: .portrait)
        try assertExpectedColumnsAndContainment()

        try rotate(to: .landscapeRight)
        try assertExpectedColumnsAndContainment()
    }

    @MainActor
    func testLockedDockerCardRemainsContainedAfterRepeatedRotation() throws {
        layoutConfiguration = .lockedDockerDetailed
        launch(extraArguments: ["--vvterm-ui-test-stats-cards-locked-docker"])
        try assertExpectedColumnsAndContainment()

        try rotate(to: .landscapeLeft)
        try assertExpectedColumnsAndContainment()

        try rotate(to: .portrait)
        try assertExpectedColumnsAndContainment()
    }

    @MainActor
    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-stats-cards-layout-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO"
        ] + extraArguments
        app.launch()

        XCTAssertTrue(container.waitForExistence(timeout: 8))
        XCTAssertTrue(card("system").waitForExistence(timeout: 5))
        XCTAssertTrue(card("cpu").waitForExistence(timeout: 5))
    }

    @MainActor
    private func rotate(to orientation: UIDeviceOrientation) throws {
        let oldWidth = container.frame.width
        XCUIDevice.shared.orientation = orientation

        let expectsWiderLayout = orientation == .landscapeLeft || orientation == .landscapeRight
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let newWidth = self.container.frame.width
            return expectsWiderLayout ? newWidth > oldWidth : newWidth < oldWidth
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    @MainActor
    private func assertExpectedColumnsAndContainment() throws {
        try assertCardsAreHorizontallyContained()
        let firstRowY = card("system").frame.minY
        let expectedColumnCount = layoutConfiguration.columnCount(for: container.frame.width)

        if expectedColumnCount == 1 {
            XCTAssertGreaterThan(
                card("cpu").frame.minY,
                firstRowY + 1,
                "A one-column layout should place the second card on the next row"
            )
        } else {
            XCTAssertEqual(
                card("cpu").frame.minY,
                firstRowY,
                accuracy: 1,
                "A multi-column layout should place the first two cards in the same row"
            )
        }

        if expectedColumnCount == 3 {
            XCTAssertEqual(
                card("memory").frame.minY,
                firstRowY,
                accuracy: 1,
                "A three-column layout should place the first three cards in the same row"
            )
        } else {
            XCTAssertGreaterThan(
                card("memory").frame.minY,
                firstRowY + 1,
                "A one- or two-column layout should place the third card below the first row"
            )
        }
    }

    @MainActor
    private func assertCardsAreHorizontallyContained(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let containerFrame = container.frame
        XCTAssertGreaterThan(containerFrame.width, 0, file: file, line: line)

        for identifier in ["system", "cpu", "memory", "gpu", "network", "storage", "processes", "docker"] {
            let element = card(identifier)
            XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing \(identifier) card", file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                element.frame.minX,
                containerFrame.minX - 1,
                "\(identifier) card escaped the leading edge",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                element.frame.maxX,
                containerFrame.maxX + 1,
                "\(identifier) card escaped the trailing edge",
                file: file,
                line: line
            )
        }
    }

    private var container: XCUIElement {
        app.descendants(matching: .any)["vvterm.stats.layout.container"]
    }

    private func card(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)["vvterm.stats.card.\(identifier)"]
    }

    private struct LayoutConfiguration {
        let minimumColumnWidth: CGFloat
        let spacing: CGFloat
        let horizontalPadding: CGFloat
        let maximumWidth: CGFloat

        static let compact = LayoutConfiguration(
            minimumColumnWidth: 292,
            spacing: 14,
            horizontalPadding: 14,
            maximumWidth: 1_180
        )
        static let detailed = LayoutConfiguration(
            minimumColumnWidth: 320,
            spacing: 18,
            horizontalPadding: 18,
            maximumWidth: 1_360
        )
        static let lockedDockerDetailed = LayoutConfiguration(
            minimumColumnWidth: 560,
            spacing: 18,
            horizontalPadding: 18,
            maximumWidth: 1_360
        )

        func columnCount(for viewportWidth: CGFloat) -> Int {
            let availableWidth = max(0, min(viewportWidth, maximumWidth) - horizontalPadding * 2)
            if availableWidth >= minimumGridWidth(for: 3) {
                return 3
            }
            if availableWidth >= minimumGridWidth(for: 2) {
                return 2
            }
            return 1
        }

        private func minimumGridWidth(for columnCount: Int) -> CGFloat {
            CGFloat(columnCount) * minimumColumnWidth + CGFloat(columnCount - 1) * spacing
        }
    }
}
#endif
