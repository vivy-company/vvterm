import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TeleportAccessBadgeTests {
    @Test(arguments: [
        (0.001, "1s"), (1.0, "1s"), (59.0, "59s"), (59.999, "60s"),
        (60.0, "1m"), (119.0, "1m"), (3599.0, "59m"),
        (3600.0, "1h"), (3660.0, "1h 1m"), (86400.0, "24h"),
    ])
    func compactDuration(remaining: TimeInterval, expected: String) {
        #expect(TeleportAccessBadge.remainingTime(remaining, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test(arguments: [0.0, -1.0, .infinity, -.infinity, .nan, Double.greatestFiniteMagnitude])
    func invalidOrExpiredDurationHasNoCountdown(remaining: TimeInterval) {
        #expect(TeleportAccessBadge.remainingTime(remaining) == nil)
    }

    @Test
    func durationUsesTheRequestedLocale() {
        #expect(TeleportAccessBadge.remainingTime(3660, locale: Locale(identifier: "fr_FR")) == "1h 1min")
    }
}
