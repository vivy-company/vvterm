import Combine
import Foundation

/// Tracks lightweight usage signals and decides when to request an App Store review.
@MainActor
final class EngagementTracker: ObservableObject {
    /// Incremented when a root view should call the system review request action.
    @Published private(set) var reviewRequestToken = 0

    private static let reviewMinimumConnections = 3
    private static let reviewMinimumUsageDays = 2
    private static let reviewCooldown: TimeInterval = 60 * 60 * 24 * 60

    private let dependencies: EngagementTrackerDependencies
    private var connectionsCountedThisLaunch: Set<UUID> = []
    private var paywallPresentedThisLaunch = false

    init(dependencies: EngagementTrackerDependencies) {
        self.dependencies = dependencies
    }

    var successfulConnectionCount: Int {
        dependencies.persistence.loadHistory().successfulConnectionCount
    }

    /// Counts a session or pane that reached a connected state, once per launch per id.
    func recordSuccessfulConnection(id: UUID, transport: String) {
        guard connectionsCountedThisLaunch.insert(id).inserted else { return }

        dependencies.analytics.trackConnectionSucceeded(transport: transport)

        var history = dependencies.persistence.loadHistory()
        history.successfulConnectionCount = incrementedWithoutOverflow(
            history.successfulConnectionCount
        )

        let today = dependencies.startOfDay(dependencies.now())
        let lastUsageDay = history.lastUsageDay.map(dependencies.startOfDay)
        if lastUsageDay != today {
            history.lastUsageDay = today
            history.usageDayCount = incrementedWithoutOverflow(history.usageDayCount)
        }
        dependencies.persistence.saveHistory(history)
    }

    /// Called when the user leaves a terminal context. Never called over a live terminal.
    func noteTerminalSessionEnded(otherTerminalsActive: Bool) {
        guard dependencies.applicationIsActive() else { return }
        guard !otherTerminalsActive else { return }
        guard !connectionsCountedThisLaunch.isEmpty else { return }

        maybeRequestReview()
    }

    /// Review requests stay quiet for the rest of a launch where any paywall appeared.
    func notePaywallPresented() {
        paywallPresentedThisLaunch = true
    }

    func requestReviewAfterPurchase() {
        fireReviewRequestIfOutsideCooldown()
    }

    private func maybeRequestReview() {
        guard !paywallPresentedThisLaunch else { return }
        let history = dependencies.persistence.loadHistory()
        guard history.successfulConnectionCount >= Self.reviewMinimumConnections,
              history.usageDayCount >= Self.reviewMinimumUsageDays else { return }
        fireReviewRequestIfOutsideCooldown(history: history)
    }

    private func fireReviewRequestIfOutsideCooldown(
        history existingHistory: EngagementHistory? = nil
    ) {
        var history = existingHistory ?? dependencies.persistence.loadHistory()
        let now = dependencies.now()
        if let lastReviewRequest = history.lastReviewRequest,
           now.timeIntervalSince(lastReviewRequest) < Self.reviewCooldown {
            return
        }

        history.lastReviewRequest = now
        dependencies.persistence.saveHistory(history)
        dependencies.analytics.trackReviewPromptRequested()
        reviewRequestToken = reviewRequestToken == Int.max ? 0 : reviewRequestToken + 1
    }

    private func incrementedWithoutOverflow(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }
}
