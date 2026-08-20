import Foundation
import StoreKit

@MainActor
final class AppStoreKitClient: StoreClient {
    private var productsById: [String: Product] = [:]

    func products(for identifiers: [String]) async throws -> [StoreProduct] {
        let products = try await Product.products(for: identifiers)
        productsById = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return products.map(StoreProduct.init)
    }

    func purchase(productId: String) async throws -> StorePurchaseResult {
        let product = try await product(for: productId)

        switch try await product.purchase() {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                return .verified(productId: transaction.productID)
            case .unverified(let transaction, _):
                return .unverified(productId: transaction.productID)
            }
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .unknown
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func entitlements(subscriptionProductIds: [String]) async -> StoreEntitlementResult {
        var verifiedProductIds = Set<String>()

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                verifiedProductIds.insert(transaction.productID)
            }
        }

        guard let product = firstCachedProduct(for: subscriptionProductIds),
              let statuses = try? await product.subscription?.status else {
            return StoreEntitlementResult(
                verifiedProductIds: verifiedProductIds,
                subscriptionEntitlements: [],
                subscriptionStatus: nil
            )
        }

        let activeStatus = statuses.first {
            $0.state == .subscribed || $0.state == .inGracePeriod
        } ?? statuses.first

        return StoreEntitlementResult(
            verifiedProductIds: verifiedProductIds,
            subscriptionEntitlements: statuses.map(StoreSubscriptionEntitlement.init),
            subscriptionStatus: activeStatus.map(StoreSubscriptionStatus.init)
        )
    }

    func introductoryOfferState(productId: String) async -> ProPlanIntroductoryOfferState {
        guard productId == VVTermProducts.proYearly,
              let product = try? await product(for: productId),
              let subscription = product.subscription,
              let offer = subscription.introductoryOffer,
              offer.paymentMode == .freeTrial,
              offer.periodCount == 1,
              offer.period.isOneWeek else {
            return .unavailable
        }

        return await subscription.isEligibleForIntroOffer
            ? .eligibleForSevenDayFreeTrial
            : .ineligible
    }

    func transactionUpdates() -> AsyncStream<StoreTransactionUpdate> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    switch result {
                    case .verified(let transaction):
                        await transaction.finish()
                        continuation.yield(.verified(productId: transaction.productID))
                    case .unverified(let transaction, _):
                        continuation.yield(.unverified(productId: transaction.productID))
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func product(for productId: String) async throws -> Product {
        if let product = productsById[productId] {
            return product
        }

        let products = try await Product.products(for: [productId])
        guard let product = products.first(where: { $0.id == productId }) else {
            throw StoreError.productNotFound
        }
        productsById[product.id] = product
        return product
    }

    private func firstCachedProduct(for productIds: [String]) -> Product? {
        return productIds.lazy.compactMap { self.productsById[$0] }.first
    }
}

private extension StoreProduct {
    init(product: Product) {
        self.init(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice
        )
    }
}

private extension StoreSubscriptionEntitlement {
    init(status: Product.SubscriptionInfo.Status) {
        let isVerified: Bool
        if case .verified = status.transaction {
            isVerified = true
        } else {
            isVerified = false
        }

        self.init(state: StoreSubscriptionState(status.state), isVerified: isVerified)
    }
}

private extension StoreSubscriptionState {
    init(_ state: Product.SubscriptionInfo.RenewalState) {
        switch state {
        case .subscribed:
            self = .subscribed
        case .inGracePeriod:
            self = .inGracePeriod
        case .inBillingRetryPeriod:
            self = .inBillingRetryPeriod
        case .expired:
            self = .expired
        case .revoked:
            self = .revoked
        default:
            self = .unknown
        }
    }
}

private extension StoreSubscriptionStatus {
    init(status: Product.SubscriptionInfo.Status) {
        let transaction: StoreVerificationResult<StoreSubscriptionTransaction>
        if case .verified(let verifiedTransaction) = status.transaction {
            transaction = .verified(StoreSubscriptionTransaction(
                productID: verifiedTransaction.productID,
                expirationDate: verifiedTransaction.expirationDate
            ))
        } else {
            transaction = .unverified
        }

        self.init(
            transaction: transaction,
            state: StoreSubscriptionState(status.state)
        )
    }
}

private extension Product.SubscriptionPeriod {
    var isOneWeek: Bool {
        (unit == .week && value == 1) || (unit == .day && value == 7)
    }
}
