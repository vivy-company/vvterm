import Foundation

nonisolated enum StoreManagerEffect: Equatable, Sendable {
    case paywallPresented(source: PaywallSource)
    case paywallCTATapped(source: PaywallSource, productID: String)
    case purchaseStarted(source: PaywallSource, productID: String)
    case purchaseSucceeded(source: PaywallSource, productID: String)
    case purchaseCancelled(source: PaywallSource, productID: String)
    case purchasePending(source: PaywallSource, productID: String)
    case purchaseFailed(source: PaywallSource, productID: String, reason: String)
    case limitHit(
        source: PaywallSource,
        generation: FreePlanGeneration,
        current: Int,
        limit: Int
    )
    case entitlementsUpdated(isPro: Bool)
    case reviewRequestedAfterPurchase
}

@MainActor
struct StoreManagerEffects {
    let record: (StoreManagerEffect) -> Void

    static let none = StoreManagerEffects { _ in }
}
