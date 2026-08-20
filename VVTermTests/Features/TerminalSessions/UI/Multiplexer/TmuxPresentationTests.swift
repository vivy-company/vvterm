import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class TmuxPresentationTests: XCTestCase {
    func testStartupBehaviorPresentationMatchesExistingLocalizedCopy() {
        XCTAssertEqual(
            TmuxStartupBehavior.vvtermManaged.displayName,
            String(localized: "Create VVTerm session")
        )
        XCTAssertEqual(
            TmuxStartupBehavior.askEveryTime.displayName,
            String(localized: "Ask every time")
        )
        XCTAssertEqual(
            TmuxStartupBehavior.skipTmux.displayName,
            String(localized: "Skip tmux")
        )

        XCTAssertEqual(
            TmuxStartupBehavior.vvtermManaged.descriptionText,
            String(localized: "Always create or attach to a VVTerm-managed tmux session for this connection.")
        )
        XCTAssertEqual(
            TmuxStartupBehavior.askEveryTime.descriptionText,
            String(localized: "Show a prompt on each new tab or split so you can choose a session.")
        )
        XCTAssertEqual(
            TmuxStartupBehavior.skipTmux.descriptionText,
            String(localized: "Start a normal shell without tmux session persistence.")
        )
    }

    func testStatusPresentationMatchesExistingCopy() {
        let expected: [(TmuxStatus, shortLabel: String, displayName: String)] = [
            (.foreground, "tmux", "Foreground"),
            (.background, "tmux", "Background"),
            (.off, "off", "Off"),
            (.missing, "tmux missing", "No tmux"),
            (.installing, "tmux install", "Installing"),
            (.unknown, "tmux", "Unknown")
        ]

        for (status, shortLabel, displayName) in expected {
            XCTAssertEqual(status.shortLabel, shortLabel)
            XCTAssertEqual(status.displayName, displayName)
        }
    }
}
