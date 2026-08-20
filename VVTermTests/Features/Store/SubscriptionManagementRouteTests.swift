import Foundation
import Testing
@testable import VVTerm

@Suite
struct SubscriptionManagementRouteTests {
    @Test
    func nativeSheetIsSelectedWhenAvailable() {
        #expect(SubscriptionManagementRoute.resolve(nativeSheetAvailable: true) == .nativeSheet)
    }

    @Test
    func appStoreWebPageIsSelectedWhenNativeSheetIsUnavailable() {
        #expect(
            SubscriptionManagementRoute.resolve(nativeSheetAvailable: false)
                == .web(URL(string: "https://apps.apple.com/account/subscriptions")!)
        )
    }
}
