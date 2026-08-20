import Foundation
import Testing
@testable import VVTerm

struct FreeTierLimitPresentationTests {
    @Test
    func currentServerLimitUsesTheExactSingularDescription() {
        #expect(
            FreeTierLimitPresentation.serverCountDescription(
                FreeTierLimits.currentMaxServers
            ) == String(localized: "1 server")
        )
    }

    @Test
    func legacyServerLimitUsesTheExactPluralDescription() {
        #expect(
            FreeTierLimitPresentation.serverCountDescription(
                FreeTierLimits.legacyMaxServers
            ) == String(
                format: String(localized: "%lld servers"),
                Int64(FreeTierLimits.legacyMaxServers)
            )
        )
    }
}
