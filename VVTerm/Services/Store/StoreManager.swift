import StoreKit
import Foundation
import Combine
import os.log

// MARK: - Store Manager

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()
    static let reviewModeCode = ReviewModeCode.value

    @Published var isPro: Bool = false
    @Published var isLifetime: Bool = false
    @Published var subscriptionStatus: Product.SubscriptionInfo.Status?
    @Published var products: [Product] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var restoreState: RestoreState = .idle
    @Published private(set) var isReviewModeEnabled: Bool = false
    @Published private(set) var lastPurchasedProductId: String?

    private var updateListenerTask: Task<Void, Error>?
    private var reviewModeExpiryTask: Task<Void, Never>?
    private var reviewModeExpiresAt: Date?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Store")
    private let reviewModeDuration: TimeInterval = 60 * 60 * 5

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

    enum RestoreState: Equatable {
        case idle
        case restoring
        case restored(hasAccess: Bool)
        case failed(String)

        static func == (lhs: RestoreState, rhs: RestoreState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.restoring, .restoring):
                return true
            case (.restored(let l), .restored(let r)):
                return l == r
            case (.failed(let l), .failed(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    // MARK: - Sorted Products

    var monthlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proMonthly }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proYearly }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == VVTermProducts.proLifetime }
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
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            do {
                products = try await Product.products(for: VVTermProducts.allProducts)
                logger.info("Loaded \(self.products.count) products")
                return
            } catch {
                logger.error("Failed to load products (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        lastPurchasedProductId = nil
        logger.info("Purchasing \(product.id)")

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
                lastPurchasedProductId = product.id
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
        restoreState = .restoring
        logger.info("Restoring purchases")
        do {
            try await AppStore.sync()
            await checkEntitlements()
            restoreState = .restored(hasAccess: isPro)
            logger.info("Purchases restored")
        } catch {
            restoreState = .failed(error.localizedDescription)
            logger.error("Failed to restore purchases: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Entitlements

    func checkEntitlements() async {
        refreshReviewModeState()
        var hasAccess = false
        var hasLifetime = false

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                switch transaction.productID {
                case VVTermProducts.proMonthly,
                     VVTermProducts.proYearly:
                    hasAccess = true
                case VVTermProducts.proLifetime:
                    hasAccess = true
                    hasLifetime = true
                default:
                    break
                }
            }
        }

        // Check subscription status for billing retry / grace period
        var activeStatus: Product.SubscriptionInfo.Status?
        if let product = monthlyProduct ?? yearlyProduct,
           let statuses = try? await product.subscription?.status {
            activeStatus = statuses.first {
                $0.state == .subscribed || $0.state == .inGracePeriod
            } ?? statuses.first

            if !hasAccess {
                for status in statuses {
                    if case .verified = status.transaction,
                       status.state == .inBillingRetryPeriod || status.state == .inGracePeriod {
                        hasAccess = true
                        break
                    }
                }
            }
        }

        isPro = hasAccess || isReviewModeEnabled
        isLifetime = hasLifetime
        subscriptionStatus = activeStatus

        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime), reviewMode=\(self.isReviewModeEnabled)")
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

    var hasActiveSubscriptionWithLifetime: Bool {
        guard isLifetime, let status = subscriptionStatus else { return false }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    // MARK: - Review Mode

    @discardableResult
    func enableReviewMode(code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.caseInsensitiveCompare(Self.reviewModeCode) == .orderedSame else {
            logger.warning("Review mode activation failed (invalid code)")
            return false
        }
        setReviewModeEnabled(true)
        return true
    }

    func setReviewModeEnabled(_ enabled: Bool) {
        guard isReviewModeEnabled != enabled else { return }
        isReviewModeEnabled = enabled

        if enabled {
            isPro = true
            isLifetime = false
            subscriptionStatus = nil
            reviewModeExpiresAt = Date().addingTimeInterval(reviewModeDuration)
            scheduleReviewModeExpiry()
            logger.info("Review mode enabled")
        } else {
            reviewModeExpiresAt = nil
            reviewModeExpiryTask?.cancel()
            reviewModeExpiryTask = nil
            logger.info("Review mode disabled")
            Task { await checkEntitlements() }
        }
    }

    private func scheduleReviewModeExpiry() {
        reviewModeExpiryTask?.cancel()
        guard let expiresAt = reviewModeExpiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        reviewModeExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.refreshReviewModeState()
            }
        }
    }

    private func refreshReviewModeState() {
        guard isReviewModeEnabled else { return }
        if let expiresAt = reviewModeExpiresAt, Date() >= expiresAt {
            setReviewModeEnabled(false)
        }
    }
}

// MARK: - Product IDs

enum VVTermProducts {
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
