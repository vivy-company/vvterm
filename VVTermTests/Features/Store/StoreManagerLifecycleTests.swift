import XCTest
@testable import VVTerm

@MainActor
final class StoreManagerLifecycleTests: XCTestCase {
    private let monthlyProduct = StoreProduct(
        id: VVTermProducts.proMonthly,
        displayName: "Monthly",
        displayPrice: "$6.49"
    )

    func testVerifiedPurchaseRefreshesEntitlementsAndCompletesPurchase() async {
        let client = StoreClientFake()
        client.purchaseResult = .verified(productId: VVTermProducts.proMonthly)
        client.entitlementResult = entitlementResult(productIds: [VVTermProducts.proMonthly])
        var recordedEffects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { recordedEffects.append($0) }
        )

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .purchased)
        XCTAssertEqual(manager.lastPurchasedProductId, VVTermProducts.proMonthly)
        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(client.purchasedProductIds, [VVTermProducts.proMonthly])
        XCTAssertEqual(client.entitlementRequestCount, 1)
        XCTAssertEqual(
            recordedEffects,
            [
                .purchaseStarted(
                    source: .general,
                    productID: VVTermProducts.proMonthly
                ),
                .entitlementsUpdated(isPro: true),
                .purchaseSucceeded(
                    source: .general,
                    productID: VVTermProducts.proMonthly
                )
            ]
        )
    }

    func testLatePurchaseResultCannotOverwriteANewerPurchase() async {
        let client = StoreClientFake()
        let firstGate = StoreValueGate<StorePurchaseResult>()
        let secondGate = StoreValueGate<StorePurchaseResult>()
        var purchaseIndex = 0
        client.purchaseHandler = { _ in
            let index = purchaseIndex
            purchaseIndex += 1
            return await (index == 0 ? firstGate : secondGate).wait()
        }
        var effects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { effects.append($0) }
        )

        let firstPurchase = Task { await manager.purchase(monthlyProduct) }
        await firstGate.waitUntilEntered()
        let secondPurchase = Task { await manager.purchase(monthlyProduct) }
        await secondGate.waitUntilEntered()

        secondGate.resume(with: .pending)
        await secondPurchase.value
        firstGate.resume(with: .verified(productId: VVTermProducts.proMonthly))
        await firstPurchase.value

        XCTAssertEqual(manager.purchaseState, .idle)
        XCTAssertNil(manager.lastPurchasedProductId)
        XCTAssertEqual(client.entitlementRequestCount, 0)
        XCTAssertEqual(
            effects,
            [
                .purchaseStarted(source: .general, productID: VVTermProducts.proMonthly),
                .purchaseStarted(source: .general, productID: VVTermProducts.proMonthly),
                .purchasePending(source: .general, productID: VVTermProducts.proMonthly)
            ]
        )
    }

    func testUnverifiedPurchaseFailsWithoutGrantingAccess() async {
        let client = StoreClientFake()
        client.purchaseResult = .unverified(productId: VVTermProducts.proMonthly)
        let manager = makeManager(client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(
            manager.purchaseState,
            .failed(StoreError.verificationFailed.localizedDescription)
        )
        XCTAssertNil(manager.lastPurchasedProductId)
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testUserCancelledPurchaseReturnsToIdle() async {
        let client = StoreClientFake()
        client.purchaseResult = .userCancelled
        let manager = makeManager(client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .idle)
        XCTAssertNil(manager.lastPurchasedProductId)
        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testPendingPurchaseReturnsToIdleWithoutGrantingAccess() async {
        let client = StoreClientFake()
        client.purchaseResult = .pending
        let manager = makeManager(client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .idle)
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testRestoreSyncsAndAppliesLifetimeEntitlement() async {
        let client = StoreClientFake()
        client.entitlementResult = entitlementResult(productIds: [VVTermProducts.proLifetime])
        let manager = makeManager(client)

        await manager.restorePurchases()

        XCTAssertEqual(client.syncCount, 1)
        XCTAssertEqual(manager.restoreState, .restored(hasAccess: true))
        XCTAssertTrue(manager.isPro)
        XCTAssertTrue(manager.isLifetime)
        manager.dismissRestoreResult()
        XCTAssertEqual(manager.restoreState, .idle)
    }

    func testLateRestoreCannotOverwriteANewerRestore() async {
        let client = StoreClientFake()
        let firstGate = StoreValueGate<Void>()
        let secondGate = StoreValueGate<Void>()
        var syncIndex = 0
        client.syncHandler = {
            let index = syncIndex
            syncIndex += 1
            await (index == 0 ? firstGate : secondGate).wait()
        }
        let manager = makeManager(client)

        let firstRestore = Task { await manager.restorePurchases() }
        await firstGate.waitUntilEntered()
        let secondRestore = Task { await manager.restorePurchases() }
        await secondGate.waitUntilEntered()

        secondGate.resume(with: ())
        await secondRestore.value
        firstGate.resume(with: ())
        await firstRestore.value

        XCTAssertEqual(client.syncCount, 2)
        XCTAssertEqual(client.entitlementRequestCount, 1)
        XCTAssertEqual(manager.restoreState, .restored(hasAccess: false))
    }

    func testLateEntitlementResultCannotOverwriteANewerCheck() async {
        let client = StoreClientFake()
        let firstGate = StoreValueGate<StoreEntitlementResult>()
        let secondGate = StoreValueGate<StoreEntitlementResult>()
        var requestIndex = 0
        client.entitlementsHandler = {
            let index = requestIndex
            requestIndex += 1
            return await (index == 0 ? firstGate : secondGate).wait()
        }
        var effects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { effects.append($0) }
        )

        let firstCheck = Task { await manager.checkEntitlements() }
        await firstGate.waitUntilEntered()
        let secondCheck = Task { await manager.checkEntitlements() }
        await secondGate.waitUntilEntered()

        secondGate.resume(with: .free)
        await secondCheck.value
        firstGate.resume(with: entitlementResult(productIds: [VVTermProducts.proLifetime]))
        await firstCheck.value

        XCTAssertEqual(manager.accessState, .free)
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(effects, [.entitlementsUpdated(isPro: false)])
    }

    func testVerifiedGraceAndBillingRetryStatesKeepAccess() async {
        for state in [StoreSubscriptionState.inGracePeriod, .inBillingRetryPeriod] {
            let client = StoreClientFake()
            client.entitlementResult = StoreEntitlementResult(
                verifiedProductIds: [],
                subscriptionEntitlements: [
                    StoreSubscriptionEntitlement(state: state, isVerified: true)
                ],
                subscriptionStatus: nil
            )
            let manager = makeManager(client)

            await manager.checkEntitlements()

            XCTAssertTrue(manager.isPro, "Expected access for \(state)")
            XCTAssertFalse(manager.isLifetime)
        }
    }

    func testUnverifiedRecoverableSubscriptionStateDoesNotGrantAccess() async {
        let client = StoreClientFake()
        client.entitlementResult = StoreEntitlementResult(
            verifiedProductIds: [],
            subscriptionEntitlements: [
                StoreSubscriptionEntitlement(state: .inGracePeriod, isVerified: false)
            ],
            subscriptionStatus: nil
        )
        let manager = makeManager(client)

        await manager.checkEntitlements()

        XCTAssertFalse(manager.isPro)
    }

    func testUnknownPurchaseReturnsToIdleWithoutRefreshingEntitlements() async {
        let client = StoreClientFake()
        client.purchaseResult = .unknown
        var recordedEffects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { recordedEffects.append($0) }
        )

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .idle)
        XCTAssertEqual(client.entitlementRequestCount, 0)
        XCTAssertEqual(
            recordedEffects,
            [
                .purchaseStarted(
                    source: .general,
                    productID: VVTermProducts.proMonthly
                )
            ]
        )
    }

    func testPaywallAndNonSuccessPurchaseEffectsAreExact() async {
        let scenarios: [(StorePurchaseResult, StoreManagerEffect)] = [
            (
                .userCancelled,
                .purchaseCancelled(
                    source: .serverLimit,
                    productID: VVTermProducts.proMonthly
                )
            ),
            (
                .pending,
                .purchasePending(
                    source: .serverLimit,
                    productID: VVTermProducts.proMonthly
                )
            ),
            (
                .unverified(productId: VVTermProducts.proMonthly),
                .purchaseFailed(
                    source: .serverLimit,
                    productID: VVTermProducts.proMonthly,
                    reason: "StoreError"
                )
            )
        ]

        for (purchaseResult, outcomeEffect) in scenarios {
            let client = StoreClientFake()
            client.purchaseResult = purchaseResult
            var recordedEffects: [StoreManagerEffect] = []
            let manager = StoreManager(
                client: client,
                effects: StoreManagerEffects { recordedEffects.append($0) }
            )

            manager.notePaywallPresented(source: .serverLimit)
            manager.notePaywallCTATapped(product: monthlyProduct)
            await manager.purchase(monthlyProduct)

            XCTAssertEqual(
                recordedEffects,
                [
                    .paywallPresented(source: .serverLimit),
                    .paywallCTATapped(
                        source: .serverLimit,
                        productID: VVTermProducts.proMonthly
                    ),
                    .purchaseStarted(
                        source: .serverLimit,
                        productID: VVTermProducts.proMonthly
                    ),
                    outcomeEffect
                ],
                "Unexpected effects for \(purchaseResult)"
            )
        }
    }

    func testReviewAfterPurchaseRoutesThroughStoreEffects() {
        let client = StoreClientFake()
        var recordedEffects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { recordedEffects.append($0) }
        )

        manager.requestReviewAfterPurchase()

        XCTAssertEqual(recordedEffects, [.reviewRequestedAfterPurchase])
    }

    func testLimitHitsRecordEachTypedPayloadExactlyOnce() {
        let inputs: [(
            source: PaywallSource,
            generation: FreePlanGeneration,
            current: Int,
            limit: Int
        )] = [
            (.serverLimit, .legacyThreeServers, Int.max, 3),
            (.workspaceLimit, .currentOneServer, 1, 1),
            (.tabLimit, .currentOneServer, 1, 1),
            (.fileTabLimit, .legacyThreeServers, 1, 1)
        ]
        var recordedEffects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: StoreClientFake(),
            effects: StoreManagerEffects { recordedEffects.append($0) }
        )

        for input in inputs {
            manager.noteLimitHit(
                source: input.source,
                generation: input.generation,
                current: input.current,
                limit: input.limit
            )
        }

        XCTAssertEqual(
            recordedEffects,
            inputs.map { input in
                .limitHit(
                    source: input.source,
                    generation: input.generation,
                    current: input.current,
                    limit: input.limit
                )
            }
        )
    }

    func testProductLoadingFailureStillGrantsMonthlyAccess() async {
        await assertProductLoadingFailureStillGrantsAccess(
            productID: VVTermProducts.proMonthly,
            expectsLifetime: false
        )
    }

    func testProductLoadingFailureStillGrantsLifetimeAccess() async {
        await assertProductLoadingFailureStillGrantsAccess(
            productID: VVTermProducts.proLifetime,
            expectsLifetime: true
        )
    }

    func testProductLoadingFailureAppliesFreeOnlyAfterEntitlementsResolve() async {
        let client = StoreClientFake()
        let productRetriesFinished = expectation(description: "All product retries finished")
        let entitlementStarted = expectation(description: "Entitlement request started")
        let entitlementReturned = expectation(description: "Entitlement request returned")
        let gate = StoreEntitlementGate()
        client.productsHandler = { throw StoreProductLoadFailure.unavailable }
        client.onProductRequest = {
            if client.productRequestCount == 3 {
                productRetriesFinished.fulfill()
            }
        }
        client.entitlementsHandler = {
            entitlementStarted.fulfill()
            let result = await gate.wait()
            entitlementReturned.fulfill()
            return result
        }
        var effects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { effects.append($0) }
        )

        manager.start()
        await fulfillment(of: [entitlementStarted, productRetriesFinished], timeout: 5)

        XCTAssertEqual(manager.accessState, .checking)
        XCTAssertTrue(manager.allowsProFeatures)
        XCTAssertTrue(effects.isEmpty)

        gate.resume(with: .free)
        await fulfillment(of: [entitlementReturned], timeout: 1)
        await Task.yield()

        XCTAssertEqual(manager.accessState, .free)
        XCTAssertFalse(manager.allowsProFeatures)
        XCTAssertEqual(effects, [.entitlementsUpdated(isPro: false)])
        manager.stop()
    }

    func testStartRunsProductsAndEntitlementsOnceAndCreatesOneListener() async {
        let client = StoreClientFake()
        client.loadedProducts = [monthlyProduct]
        client.entitlementResult = entitlementResult(productIds: [VVTermProducts.proMonthly])
        let started = expectation(description: "Startup completed")
        client.onEntitlementRequest = { started.fulfill() }
        let manager = makeManager(client)

        manager.start()
        manager.start()
        await fulfillment(of: [started], timeout: 1)
        await Task.yield()

        XCTAssertEqual(manager.products, [monthlyProduct])
        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(client.events, ["updates", "products", "entitlements"])
        XCTAssertEqual(client.productRequestCount, 1)
        XCTAssertEqual(client.entitlementRequestCount, 1)
        XCTAssertEqual(client.transactionUpdateRequestCount, 1)
        manager.stop()
    }

    func testStartLoadsProductsBeforeRecoveringSubscriptionEntitlements() async {
        let client = StoreClientFake()
        let productGate = StoreValueGate<[StoreProduct]>()
        let entitlementStarted = expectation(description: "Entitlement request started")
        client.productsHandler = {
            await productGate.wait()
        }
        client.entitlementResult = StoreEntitlementResult(
            verifiedProductIds: [],
            subscriptionEntitlements: [
                StoreSubscriptionEntitlement(
                    state: .inBillingRetryPeriod,
                    isVerified: true
                )
            ],
            subscriptionStatus: nil
        )
        client.onEntitlementRequest = { entitlementStarted.fulfill() }
        let manager = makeManager(client)

        manager.start()
        await productGate.waitUntilEntered()

        XCTAssertEqual(client.entitlementRequestCount, 0)
        XCTAssertEqual(manager.accessState, .checking)

        productGate.resume(with: [monthlyProduct])
        await fulfillment(of: [entitlementStarted], timeout: 1)
        await Task.yield()

        XCTAssertEqual(client.events, ["updates", "products", "entitlements"])
        XCTAssertEqual(manager.products, [monthlyProduct])
        XCTAssertEqual(manager.accessState, .pro)
        manager.stop()
    }

    func testUnverifiedUpdateIsIgnoredBeforeVerifiedUpdateRefreshesEntitlements() async {
        let client = StoreClientFake()
        client.entitlementResults = [
            .free,
            entitlementResult(productIds: [VVTermProducts.proMonthly])
        ]
        let startup = expectation(description: "Startup entitlements checked")
        let update = expectation(description: "Update entitlements checked")
        client.onEntitlementRequest = {
            if client.entitlementRequestCount == 1 {
                startup.fulfill()
            } else if client.entitlementRequestCount == 2 {
                update.fulfill()
            }
        }
        let manager = makeManager(client)

        manager.start()
        await fulfillment(of: [startup], timeout: 1)
        client.emit(.unverified(productId: VVTermProducts.proMonthly))
        client.emit(.verified(productId: VVTermProducts.proMonthly))
        await fulfillment(of: [update], timeout: 1)
        await Task.yield()

        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(client.entitlementRequestCount, 2)
        manager.stop()
    }

    func testStopCancelsTransactionStream() async {
        let client = StoreClientFake()
        let terminated = expectation(description: "Transaction stream terminated")
        client.onTransactionStreamTermination = { terminated.fulfill() }
        let manager = makeManager(client)

        manager.start()
        manager.stop()
        await fulfillment(of: [terminated], timeout: 1)

        XCTAssertEqual(client.transactionStreamTerminationCount, 1)
    }

    func testStopRejectsLateEntitlementResultFromVerifiedUpdate() async {
        let client = StoreClientFake()
        let startupCompleted = expectation(description: "Startup completed")
        client.onEntitlementRequest = { startupCompleted.fulfill() }
        var recordedEffects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { recordedEffects.append($0) }
        )

        manager.start()
        await fulfillment(of: [startupCompleted], timeout: 1)
        await Task.yield()
        client.onEntitlementRequest = nil
        XCTAssertFalse(manager.isPro)

        let gate = StoreEntitlementGate()
        let updateStarted = expectation(description: "Update entitlement request started")
        let updateReturned = expectation(description: "Update entitlement request returned")
        client.entitlementsHandler = {
            updateStarted.fulfill()
            let result = await gate.wait()
            updateReturned.fulfill()
            return result
        }

        client.emit(.verified(productId: VVTermProducts.proMonthly))
        await fulfillment(of: [updateStarted], timeout: 1)
        manager.stop()
        gate.resume(with: entitlementResult(productIds: [VVTermProducts.proMonthly]))
        await fulfillment(of: [updateReturned], timeout: 1)
        await Task.yield()

        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(recordedEffects, [.entitlementsUpdated(isPro: false)])
    }

    func testStopRejectsLateStartupEntitlementResult() async {
        let client = StoreClientFake()
        let entitlementStarted = expectation(description: "Startup entitlement request started")
        let entitlementReturned = expectation(description: "Startup entitlement request returned")
        let gate = StoreEntitlementGate()
        client.entitlementsHandler = {
            entitlementStarted.fulfill()
            let result = await gate.wait()
            entitlementReturned.fulfill()
            return result
        }
        var effects: [StoreManagerEffect] = []
        let manager = StoreManager(
            client: client,
            effects: StoreManagerEffects { effects.append($0) }
        )

        manager.start()
        await fulfillment(of: [entitlementStarted], timeout: 1)
        XCTAssertEqual(manager.accessState, .checking)
        manager.stop()
        gate.resume(with: entitlementResult(productIds: [VVTermProducts.proMonthly]))
        await fulfillment(of: [entitlementReturned], timeout: 1)
        await Task.yield()

        XCTAssertEqual(manager.accessState, .checking)
        XCTAssertTrue(effects.isEmpty)
    }

    func testOwnerReleaseCancelsStartupAndTransactionStream() async {
        let client = StoreClientFake()
        let productLoadStarted = expectation(description: "Product load started")
        let productLoadCancelled = expectation(description: "Product load cancelled")
        let streamTerminated = expectation(description: "Transaction stream terminated")
        client.productsHandler = {
            productLoadStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            } catch {
                productLoadCancelled.fulfill()
                throw CancellationError()
            }
        }
        client.onTransactionStreamTermination = { streamTerminated.fulfill() }
        var manager: StoreManager? = makeManager(client)
        weak var weakManager = manager

        manager?.start()
        await fulfillment(of: [productLoadStarted], timeout: 1)
        manager = nil
        await fulfillment(
            of: [productLoadCancelled, streamTerminated],
            timeout: 1
        )

        XCTAssertNil(weakManager)
    }

    func testOwnerReleaseAfterStartupCompletesTerminatesTransactionStream() async {
        let client = StoreClientFake()
        client.loadedProducts = [monthlyProduct]
        client.entitlementResult = entitlementResult(
            productIds: [VVTermProducts.proMonthly]
        )
        let startupCompleted = expectation(description: "Startup completed")
        let streamTerminated = expectation(description: "Transaction stream terminated")
        client.onEntitlementRequest = { startupCompleted.fulfill() }
        client.onTransactionStreamTermination = { streamTerminated.fulfill() }
        var manager: StoreManager? = makeManager(client)
        weak var weakManager = manager

        manager?.start()
        await fulfillment(of: [startupCompleted], timeout: 1)
        await Task.yield()
        XCTAssertTrue(manager?.isPro == true)
        manager = nil
        await fulfillment(of: [streamTerminated], timeout: 1)

        XCTAssertNil(weakManager)
        XCTAssertEqual(client.entitlementRequestCount, 1)
        XCTAssertEqual(client.transactionStreamTerminationCount, 1)
    }

    private func entitlementResult(productIds: Set<String>) -> StoreEntitlementResult {
        StoreEntitlementResult(
            verifiedProductIds: productIds,
            subscriptionEntitlements: [],
            subscriptionStatus: nil
        )
    }

    private func makeManager(_ client: StoreClientFake) -> StoreManager {
        StoreManager(client: client, effects: .none)
    }

    private func assertProductLoadingFailureStillGrantsAccess(
        productID: String,
        expectsLifetime: Bool
    ) async {
        let client = StoreClientFake()
        let productRetriesFinished = expectation(description: "All product retries finished")
        let entitlementResolved = expectation(description: "Entitlements resolved")
        client.productsHandler = { throw StoreProductLoadFailure.unavailable }
        client.onProductRequest = {
            if client.productRequestCount == 3 {
                productRetriesFinished.fulfill()
            }
        }
        client.entitlementResult = entitlementResult(productIds: [productID])
        client.onEntitlementRequest = { entitlementResolved.fulfill() }
        let manager = makeManager(client)

        manager.start()
        await fulfillment(of: [entitlementResolved, productRetriesFinished], timeout: 5)
        await Task.yield()

        XCTAssertEqual(manager.accessState, .pro)
        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(manager.isLifetime, expectsLifetime)
        XCTAssertTrue(manager.products.isEmpty)
        XCTAssertEqual(client.productRequestCount, 3)
        XCTAssertEqual(client.entitlementRequestCount, 1)
        manager.stop()
    }
}

private enum StoreProductLoadFailure: Error {
    case unavailable
}

@MainActor
private final class StoreClientFake: StoreClient {
    var loadedProducts: [StoreProduct] = []
    var purchaseResult: StorePurchaseResult = .pending
    var entitlementResult = StoreEntitlementResult.free
    var entitlementResults: [StoreEntitlementResult] = []
    var introductoryOfferState: ProPlanIntroductoryOfferState = .unavailable
    var onEntitlementRequest: (() -> Void)?
    var onProductRequest: (() -> Void)?
    var onTransactionStreamTermination: (() -> Void)?
    var productsHandler: (() async throws -> [StoreProduct])?
    var purchaseHandler: ((String) async throws -> StorePurchaseResult)?
    var syncHandler: (() async throws -> Void)?
    var entitlementsHandler: (() async -> StoreEntitlementResult)?

    private(set) var events: [String] = []
    private(set) var purchasedProductIds: [String] = []
    private(set) var syncCount = 0
    private(set) var entitlementRequestCount = 0
    private(set) var productRequestCount = 0
    private(set) var transactionUpdateRequestCount = 0
    private(set) var transactionStreamTerminationCount = 0

    private var updatesContinuation: AsyncStream<StoreTransactionUpdate>.Continuation?

    func products(for identifiers: [String]) async throws -> [StoreProduct] {
        events.append("products")
        productRequestCount += 1
        onProductRequest?()
        if let productsHandler {
            return try await productsHandler()
        }
        return loadedProducts.filter { identifiers.contains($0.id) }
    }

    func purchase(productId: String) async throws -> StorePurchaseResult {
        purchasedProductIds.append(productId)
        if let purchaseHandler {
            return try await purchaseHandler(productId)
        }
        return purchaseResult
    }

    func sync() async throws {
        syncCount += 1
        if let syncHandler {
            try await syncHandler()
        }
    }

    func entitlements(subscriptionProductIds: [String]) async -> StoreEntitlementResult {
        events.append("entitlements")
        entitlementRequestCount += 1
        onEntitlementRequest?()
        if let entitlementsHandler {
            return await entitlementsHandler()
        }
        if !entitlementResults.isEmpty {
            return entitlementResults.removeFirst()
        }
        return entitlementResult
    }

    func introductoryOfferState(productId: String) async -> ProPlanIntroductoryOfferState {
        introductoryOfferState
    }

    func transactionUpdates() -> AsyncStream<StoreTransactionUpdate> {
        events.append("updates")
        transactionUpdateRequestCount += 1
        return AsyncStream { continuation in
            updatesContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    transactionStreamTerminationCount += 1
                    onTransactionStreamTermination?()
                }
            }
        }
    }

    func emit(_ update: StoreTransactionUpdate) {
        updatesContinuation?.yield(update)
    }
}

@MainActor
private final class StoreEntitlementGate {
    private var continuation: CheckedContinuation<StoreEntitlementResult, Never>?

    func wait() async -> StoreEntitlementResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with result: StoreEntitlementResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class StoreValueGate<Value: Sendable> {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var valueContinuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            valueContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume(with value: Value) {
        valueContinuation?.resume(returning: value)
        valueContinuation = nil
    }
}
