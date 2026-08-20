import Foundation

nonisolated struct StoreEntitlementResult: Equatable, Sendable {
    static let free = StoreEntitlementResult(
        verifiedProductIds: [],
        subscriptionEntitlements: [],
        subscriptionStatus: nil
    )

    let verifiedProductIds: Set<String>
    let subscriptionEntitlements: [StoreSubscriptionEntitlement]
    let subscriptionStatus: StoreSubscriptionStatus?
}

@MainActor
protocol StoreClient: AnyObject, Sendable {
    func products(for identifiers: [String]) async throws -> [StoreProduct]
    func purchase(productId: String) async throws -> StorePurchaseResult
    func sync() async throws
    func entitlements(subscriptionProductIds: [String]) async -> StoreEntitlementResult
    func introductoryOfferState(productId: String) async -> ProPlanIntroductoryOfferState
    func transactionUpdates() -> AsyncStream<StoreTransactionUpdate>
}
