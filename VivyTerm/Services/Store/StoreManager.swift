import StoreKit
import Foundation
import Combine
import os.log

// MARK: - Store Manager

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published var isPro: Bool = false
    @Published var isLifetime: Bool = false
    @Published var subscriptionStatus: Product.SubscriptionInfo.Status?
    @Published var products: [Product] = []
    @Published var purchaseState: PurchaseState = .idle

    private var updateListenerTask: Task<Void, Error>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Store")

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case purchased
        case failed(String)

        static func == (lhs: PurchaseState, rhs: PurchaseState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.purchasing, .purchasing), (.purchased, .purchased):
                return true
            case (.failed(let l), .failed(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    // MARK: - Sorted Products

    var monthlyProduct: Product? {
        products.first { $0.id == VivyTermProducts.proMonthly }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == VivyTermProducts.proYearly }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == VivyTermProducts.proLifetime }
    }

    // MARK: - Initialization

    private init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await checkEntitlements()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            products = try await Product.products(for: VivyTermProducts.allProducts)
            logger.info("Loaded \(self.products.count) products")
        } catch {
            logger.error("Failed to load products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        logger.info("Purchasing \(product.id)")

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
                purchaseState = .purchased
                logger.info("Purchase successful: \(product.id)")

            case .userCancelled:
                purchaseState = .idle
                logger.info("Purchase cancelled by user")

            case .pending:
                purchaseState = .idle
                logger.info("Purchase pending")

            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
            logger.error("Purchase failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        logger.info("Restoring purchases")
        do {
            try await AppStore.sync()
            await checkEntitlements()
            logger.info("Purchases restored")
        } catch {
            logger.error("Failed to restore purchases: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Entitlements

    func checkEntitlements() async {
        var hasAccess = false
        var hasLifetime = false

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                switch transaction.productID {
                case VivyTermProducts.proMonthly,
                     VivyTermProducts.proYearly:
                    hasAccess = true
                case VivyTermProducts.proLifetime:
                    hasAccess = true
                    hasLifetime = true
                default:
                    break
                }
            }
        }

        isPro = hasAccess
        isLifetime = hasLifetime

        // Get subscription status for UI
        if let product = monthlyProduct ?? yearlyProduct {
            subscriptionStatus = try? await product.subscription?.status.first
        }

        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime)")
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await self.checkEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Subscription Info

    var subscriptionExpirationDate: Date? {
        guard let status = subscriptionStatus else { return nil }
        guard case .verified(let transaction) = status.transaction else { return nil }
        return transaction.expirationDate
    }

    var isSubscriptionActive: Bool {
        guard let status = subscriptionStatus else { return isLifetime }
        return status.state == .subscribed || status.state == .inGracePeriod
    }
}

// MARK: - Product IDs

enum VivyTermProducts {
    // Auto-renewable subscriptions (same group)
    static let proMonthly = "com.vivy.vivyterm.pro.monthly"
    static let proYearly = "com.vivy.vivyterm.pro.yearly"

    // Non-consumable (one-time)
    static let proLifetime = "com.vivy.vivyterm.pro.lifetime"

    static let subscriptionGroupId = "vivyterm_pro"
    static let allProducts = [proMonthly, proYearly, proLifetime]
}

// MARK: - Store Error

enum StoreError: LocalizedError {
    case verificationFailed
    case productNotFound
    case purchaseFailed(String)

    var errorDescription: String? {
        switch self {
        case .verificationFailed: return String(localized: "Purchase verification failed")
        case .productNotFound: return String(localized: "Product not found")
        case .purchaseFailed(let msg): return String(format: String(localized: "Purchase failed: %@"), msg)
        }
    }
}
