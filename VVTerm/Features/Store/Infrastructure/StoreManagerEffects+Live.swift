extension StoreManagerEffects {
    static func live(
        analytics: any StoreAnalyticsRecording,
        engagementTracker: EngagementTracker
    ) -> Self {
        StoreManagerEffects { effect in
            switch effect {
            case .paywallPresented(let source):
                engagementTracker.notePaywallPresented()
                analytics.record(.paywallPresented(source: source))
            case .paywallCTATapped(let source, let productID):
                analytics.record(.paywallCTATapped(source: source, productID: productID))
            case .purchaseStarted(let source, let productID):
                analytics.record(.purchaseStarted(source: source, productID: productID))
            case .purchaseSucceeded(let source, let productID):
                analytics.record(.purchaseSucceeded(source: source, productID: productID))
            case .purchaseCancelled(let source, let productID):
                analytics.record(.purchaseCancelled(source: source, productID: productID))
            case .purchasePending(let source, let productID):
                analytics.record(.purchasePending(source: source, productID: productID))
            case .purchaseFailed(let source, let productID, let reason):
                analytics.record(.purchaseFailed(
                    source: source,
                    productID: productID,
                    reason: reason
                ))
            case .limitHit(let source, let generation, let current, let limit):
                analytics.record(.limitHit(
                    source: source,
                    generation: generation,
                    current: current,
                    limit: limit
                ))
            case .entitlementsUpdated(let isPro):
                analytics.record(.entitlementsUpdated(isPro: isPro))
            case .reviewRequestedAfterPurchase:
                engagementTracker.requestReviewAfterPurchase()
            }
        }
    }
}
