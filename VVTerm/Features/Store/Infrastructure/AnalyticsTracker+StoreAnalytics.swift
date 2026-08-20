extension AnalyticsTracker: StoreAnalyticsRecording {
    func record(_ event: StoreAnalyticsEvent) {
        switch event {
        case .paywallPresented(let source):
            trackPaywallViewed(source: source.rawValue)
        case .paywallCTATapped(let source, let productID):
            trackPaywallCTATapped(
                source: source.rawValue,
                productId: productID
            )
        case .purchaseStarted(let source, let productID):
            trackPurchaseStarted(
                source: source.rawValue,
                productId: productID
            )
        case .purchaseSucceeded(let source, let productID):
            trackPurchaseSucceeded(
                source: source.rawValue,
                productId: productID
            )
        case .purchaseCancelled(let source, let productID):
            trackPurchaseCancelled(
                source: source.rawValue,
                productId: productID
            )
        case .purchasePending(let source, let productID):
            trackPurchasePending(
                source: source.rawValue,
                productId: productID
            )
        case .purchaseFailed(let source, let productID, let reason):
            trackPurchaseFailed(
                source: source.rawValue,
                productId: productID,
                reason: reason
            )
        case .limitHit(let source, let generation, let current, let limit):
            trackLimitHit(
                source: source.rawValue,
                generation: generation.rawValue,
                current: current,
                limit: limit
            )
        case .entitlementsUpdated(let isPro):
            trackAppLaunched(isPro: isPro)
        }
    }
}
