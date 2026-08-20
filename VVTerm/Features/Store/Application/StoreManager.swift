import Foundation
import Combine
import os.log

nonisolated enum StoreAccessState: Equatable, Sendable {
    case checking
    case free
    case pro
}

nonisolated struct StoreEntitlementSnapshot: Equatable, Sendable {
    static let checking = StoreEntitlementSnapshot(
        accessState: .checking,
        hasLifetimeAccess: false,
        subscriptionStatus: nil
    )

    static let free = StoreEntitlementSnapshot(
        accessState: .free,
        hasLifetimeAccess: false,
        subscriptionStatus: nil
    )

    let accessState: StoreAccessState
    let hasLifetimeAccess: Bool
    let subscriptionStatus: StoreSubscriptionStatus?

    var hasStoreAccess: Bool {
        accessState == .pro
    }
}

// MARK: - Store Manager

@MainActor
final class StoreManager: ObservableObject {
    private final class StartupToken {}
    private final class TransactionListenerToken {}

    @Published private(set) var entitlementSnapshot = StoreEntitlementSnapshot.checking
    @Published private(set) var products: [StoreProduct] = []
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published private(set) var restoreState: RestoreState = .idle
    @Published private(set) var lastPurchasedProductId: String?
    private(set) var activePaywallSource: PaywallSource = .general
    private(set) var hasPresentedPaywallThisLaunch = false

    private var startupTask: Task<Void, Never>?
    private var startupToken: StartupToken?
    private var updateListenerTask: Task<Void, Never>?
    private var transactionListenerToken: TransactionListenerToken?
    private var productOperationID: UUID?
    private var entitlementOperationID: UUID?
    private var purchaseOperationID: UUID?
    private var restoreOperationID: UUID?
    private let client: any StoreClient
    private let effects: StoreManagerEffects
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VVTerm",
        category: "Store"
    )

    var isPro: Bool {
        entitlementSnapshot.hasStoreAccess
    }

    var accessState: StoreAccessState {
        entitlementSnapshot.accessState
    }

    /// Do not enforce Free limits before StoreKit resolves entitlements.
    var allowsProFeatures: Bool {
        accessState != .free
    }

    var isLifetime: Bool {
        entitlementSnapshot.hasLifetimeAccess
    }

    var subscriptionStatus: StoreSubscriptionStatus? {
        entitlementSnapshot.subscriptionStatus
    }

    // MARK: - Sorted Products

    var monthlyProduct: StoreProduct? {
        products.first { $0.id == VVTermProducts.proMonthly }
    }

    var yearlyProduct: StoreProduct? {
        products.first { $0.id == VVTermProducts.proYearly }
    }

    var lifetimeProduct: StoreProduct? {
        products.first { $0.id == VVTermProducts.proLifetime }
    }

    // MARK: - Initialization

    init(
        client: any StoreClient,
        effects: StoreManagerEffects
    ) {
        self.client = client
        self.effects = effects
    }

    func start() {
        guard startupTask == nil, updateListenerTask == nil else { return }
        startTransactionListener()
        let token = StartupToken()
        startupToken = token
        let productOperationID = UUID()
        self.productOperationID = productOperationID
        let entitlementOperationID = UUID()
        self.entitlementOperationID = entitlementOperationID
        let client = self.client
        let logger = self.logger
        startupTask = Task { [weak self, client, logger, token] in
            let loadedProducts = await Self.loadProducts(using: client, logger: logger)
            guard !Task.isCancelled else { return }
            self?.applyStartupProducts(
                loadedProducts,
                token: token,
                operationID: productOperationID
            )

            let result = await client.entitlements(
                subscriptionProductIds: Self.subscriptionProductIds
            )
            guard !Task.isCancelled else { return }
            self?.applyStartupEntitlementResult(
                result,
                token: token,
                operationID: entitlementOperationID
            )
        }
    }

    func stop() {
        startupToken = nil
        transactionListenerToken = nil
        productOperationID = nil
        entitlementOperationID = nil
        purchaseOperationID = nil
        restoreOperationID = nil
        startupTask?.cancel()
        updateListenerTask?.cancel()
        startupTask = nil
        updateListenerTask = nil
    }

    deinit {
        startupTask?.cancel()
        updateListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        let operationID = UUID()
        productOperationID = operationID
        guard let loadedProducts = await Self.loadProducts(using: client, logger: logger) else {
            if productOperationID == operationID {
                productOperationID = nil
            }
            return
        }
        guard productOperationID == operationID else { return }
        products = loadedProducts
        productOperationID = nil
    }

    private static func loadProducts(
        using client: any StoreClient,
        logger: Logger
    ) async -> [StoreProduct]? {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            do {
                let products = try await client.products(for: VVTermProducts.allProducts)
                try Task.checkCancellation()
                logger.info("Loaded \(products.count) products")
                return products
            } catch is CancellationError {
                return nil
            } catch {
                logger.error("Failed to load products (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                        )
                    } catch {
                        return nil
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Paywall Presentation

    func notePaywallPresented(source: PaywallSource) {
        activePaywallSource = source
        hasPresentedPaywallThisLaunch = true
        effects.record(.paywallPresented(source: source))
    }

    func notePaywallCTATapped(product: StoreProduct) {
        effects.record(.paywallCTATapped(
            source: activePaywallSource,
            productID: product.id
        ))
    }

    func requestReviewAfterPurchase() {
        effects.record(.reviewRequestedAfterPurchase)
    }

    func noteLimitHit(
        source: PaywallSource,
        generation: FreePlanGeneration,
        current: Int,
        limit: Int
    ) {
        effects.record(.limitHit(
            source: source,
            generation: generation,
            current: current,
            limit: limit
        ))
    }

    func introductoryOfferState(for product: StoreProduct) async -> ProPlanIntroductoryOfferState {
        await client.introductoryOfferState(productId: product.id)
    }

    // MARK: - Purchase

    func purchase(_ product: StoreProduct) async {
        let operationID = UUID()
        purchaseOperationID = operationID
        defer {
            if purchaseOperationID == operationID {
                purchaseOperationID = nil
            }
        }
        let source = activePaywallSource
        purchaseState = .purchasing
        lastPurchasedProductId = nil
        effects.record(.purchaseStarted(
            source: source,
            productID: product.id
        ))
        logger.info("Purchasing \(product.id)")

        do {
            let result = try await client.purchase(productId: product.id)
            guard purchaseOperationID == operationID else { return }

            switch result {
            case .verified:
                await checkEntitlements()
                guard purchaseOperationID == operationID else { return }
                applySuccessfulPurchase(of: product, source: source)

            case .unverified(let productId):
                logger.error(
                    "StoreKit transaction verification failed for product \(productId, privacy: .public)"
                )
                throw StoreError.verificationFailed

            case .userCancelled:
                effects.record(.purchaseCancelled(
                    source: source,
                    productID: product.id
                ))
                applyIdlePurchaseState(logMessage: "Purchase cancelled by user")

            case .pending:
                effects.record(.purchasePending(
                    source: source,
                    productID: product.id
                ))
                applyIdlePurchaseState(logMessage: "Purchase pending")

            case .unknown:
                purchaseState = .idle
            }
        } catch {
            guard purchaseOperationID == operationID else { return }
            effects.record(.purchaseFailed(
                source: source,
                productID: product.id,
                reason: String(describing: type(of: error))
            ))
            purchaseState = .failed(error.localizedDescription)
            logger.error("Purchase failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        let operationID = UUID()
        restoreOperationID = operationID
        defer {
            if restoreOperationID == operationID {
                restoreOperationID = nil
            }
        }
        restoreState = .restoring
        logger.info("Restoring purchases")
        do {
            try await client.sync()
            guard restoreOperationID == operationID else { return }
            await checkEntitlements()
            guard restoreOperationID == operationID else { return }
            applyRestoreResult(hasAccess: isPro)
        } catch {
            guard restoreOperationID == operationID else { return }
            restoreState = .failed(error.localizedDescription)
            logger.error("Failed to restore purchases: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Entitlements

    func checkEntitlements() async {
        let operationID = UUID()
        entitlementOperationID = operationID
        let result = await client.entitlements(
            subscriptionProductIds: Self.subscriptionProductIds
        )
        guard !Task.isCancelled else {
            if entitlementOperationID == operationID {
                entitlementOperationID = nil
            }
            return
        }
        guard entitlementOperationID == operationID else { return }
        applyEntitlementResult(result)
        entitlementOperationID = nil
    }

    func dismissRestoreResult() {
        guard restoreState != .restoring else { return }
        restoreState = .idle
    }

    private func applyStartupEntitlementResult(
        _ result: StoreEntitlementResult,
        token: StartupToken,
        operationID: UUID
    ) {
        guard startupToken === token, entitlementOperationID == operationID else { return }
        applyEntitlementResult(result)
        entitlementOperationID = nil
    }

    private func applyStartupProducts(
        _ products: [StoreProduct]?,
        token: StartupToken,
        operationID: UUID
    ) {
        guard startupToken === token, productOperationID == operationID else { return }
        if let products {
            self.products = products
        }
        productOperationID = nil
    }

    private func applyEntitlementResult(_ result: StoreEntitlementResult) {
        let hasLifetime = result.verifiedProductIds.contains(VVTermProducts.proLifetime)
        let hasVerifiedSubscription = result.verifiedProductIds.contains(VVTermProducts.proMonthly)
            || result.verifiedProductIds.contains(VVTermProducts.proYearly)
        let hasRecoverableSubscription = result.subscriptionEntitlements.contains {
            $0.isVerified && ($0.state == .inBillingRetryPeriod || $0.state == .inGracePeriod)
        }

        applyEntitlements(
            hasAccess: hasLifetime || hasVerifiedSubscription || hasRecoverableSubscription,
            hasLifetime: hasLifetime,
            status: result.subscriptionStatus
        )
    }

    // MARK: - Transaction Listener

    private func startTransactionListener() {
        guard updateListenerTask == nil else { return }
        let updates = client.transactionUpdates()
        let token = TransactionListenerToken()
        transactionListenerToken = token
        let client = self.client
        let logger = self.logger
        updateListenerTask = Task { [weak self, client, logger, token] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .verified:
                    guard let self else { return }
                    let operationID = UUID()
                    self.entitlementOperationID = operationID
                    let result = await client.entitlements(
                        subscriptionProductIds: Self.subscriptionProductIds
                    )
                    guard !Task.isCancelled else { return }
                    self.applyTransactionEntitlementResult(
                        result,
                        token: token,
                        operationID: operationID
                    )
                case .unverified(let productId):
                    logger.error(
                        "Ignored unverified StoreKit update for product \(productId, privacy: .public)"
                    )
                }
            }
        }
    }

    private func applyTransactionEntitlementResult(
        _ result: StoreEntitlementResult,
        token: TransactionListenerToken,
        operationID: UUID
    ) {
        guard transactionListenerToken === token,
              entitlementOperationID == operationID else { return }
        applyEntitlementResult(result)
        entitlementOperationID = nil
    }

    // MARK: - Subscription Info

    var subscriptionExpirationDate: Date? {
        subscriptionStatus?.expirationDate
    }

    var isSubscriptionActive: Bool {
        guard let status = subscriptionStatus else { return isLifetime }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    var hasActiveSubscriptionWithLifetime: Bool {
        guard isLifetime, let status = subscriptionStatus else { return false }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    private func applySuccessfulPurchase(of product: StoreProduct, source: PaywallSource) {
        lastPurchasedProductId = product.id
        purchaseState = .purchased
        effects.record(.purchaseSucceeded(
            source: source,
            productID: product.id
        ))
        logger.info("Purchase successful: \(product.id)")
    }

    private func applyIdlePurchaseState(logMessage: String) {
        purchaseState = .idle
        logger.info("\(logMessage)")
    }

    private func applyRestoreResult(hasAccess: Bool) {
        restoreState = .restored(hasAccess: hasAccess)
        logger.info("Purchases restored")
    }

    private func applyEntitlements(
        hasAccess: Bool,
        hasLifetime: Bool,
        status: StoreSubscriptionStatus?
    ) {
        entitlementSnapshot = StoreEntitlementSnapshot(
            accessState: hasAccess ? .pro : .free,
            hasLifetimeAccess: hasLifetime,
            subscriptionStatus: status
        )
        effects.record(.entitlementsUpdated(isPro: isPro))
        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime)")
    }

    private static let subscriptionProductIds = [
        VVTermProducts.proMonthly,
        VVTermProducts.proYearly
    ]
}
