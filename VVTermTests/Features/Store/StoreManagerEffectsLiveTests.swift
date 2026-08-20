import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class StoreAnalyticsRecorderSpy: StoreAnalyticsRecording {
    private(set) var events: [StoreAnalyticsEvent] = []

    func record(_ event: StoreAnalyticsEvent) {
        events.append(event)
    }
}

@MainActor
private final class StoreEngagementPersistenceSpy: EngagementPersisting {
    private var history = EngagementHistory.empty

    func loadHistory() -> EngagementHistory {
        history
    }

    func saveHistory(_ history: EngagementHistory) {
        self.history = history
    }
}

@MainActor
private final class StoreEngagementAnalyticsSpy: EngagementAnalytics {
    func trackConnectionSucceeded(transport: String) {}
    func trackReviewPromptRequested() {}
}

@MainActor
struct StoreManagerEffectsLiveTests {
    @Test
    func everyStoreEffectRoutesToExactTypedAnalyticsEventOnce() {
        let analytics = StoreAnalyticsRecorderSpy()
        let effects = StoreManagerEffects.live(
            analytics: analytics,
            engagementTracker: makeEngagementTracker()
        )
        let mappings: [(StoreManagerEffect, StoreAnalyticsEvent?)] = [
            (.paywallPresented(source: .serverLimit), .paywallPresented(source: .serverLimit)),
            (
                .paywallCTATapped(source: .workspaceLimit, productID: "cta"),
                .paywallCTATapped(source: .workspaceLimit, productID: "cta")
            ),
            (
                .purchaseStarted(source: .tabLimit, productID: "started"),
                .purchaseStarted(source: .tabLimit, productID: "started")
            ),
            (
                .purchaseSucceeded(source: .fileTabLimit, productID: "succeeded"),
                .purchaseSucceeded(source: .fileTabLimit, productID: "succeeded")
            ),
            (
                .purchaseCancelled(source: .splitPane, productID: "cancelled"),
                .purchaseCancelled(source: .splitPane, productID: "cancelled")
            ),
            (
                .purchasePending(source: .customEnvironment, productID: "pending"),
                .purchasePending(source: .customEnvironment, productID: "pending")
            ),
            (
                .purchaseFailed(source: .snippetLimit, productID: "failed", reason: "reason"),
                .purchaseFailed(source: .snippetLimit, productID: "failed", reason: "reason")
            ),
            (
                .limitHit(
                    source: .sidebarBanner,
                    generation: .legacyThreeServers,
                    current: Int.max,
                    limit: 3
                ),
                .limitHit(
                    source: .sidebarBanner,
                    generation: .legacyThreeServers,
                    current: Int.max,
                    limit: 3
                )
            ),
            (.entitlementsUpdated(isPro: true), .entitlementsUpdated(isPro: true)),
            (.reviewRequestedAfterPurchase, nil)
        ]

        for (effect, _) in mappings {
            effects.record(effect)
        }

        #expect(analytics.events == mappings.compactMap(\.1))
    }

    private func makeEngagementTracker() -> EngagementTracker {
        EngagementTracker(
            dependencies: EngagementTrackerDependencies(
                persistence: StoreEngagementPersistenceSpy(),
                analytics: StoreEngagementAnalyticsSpy(),
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                startOfDay: { $0 },
                applicationIsActive: { true }
            )
        )
    }
}
