import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct EngagementTrackerTests {
    @Test
    func qualifyingSessionRequestsReviewAfterExactUsageSignals() {
        let dayOne = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = EngagementTestClock(now: dayOne)
        let persistence = EngagementPersistenceSpy()
        let analytics = EngagementAnalyticsSpy()
        let tracker = makeTracker(
            persistence: persistence,
            analytics: analytics,
            clock: clock
        )
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        tracker.recordSuccessfulConnection(id: firstID, transport: "ssh")
        tracker.recordSuccessfulConnection(id: firstID, transport: "ignored-duplicate")
        clock.now = dayOne.addingTimeInterval(86_400)
        tracker.recordSuccessfulConnection(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            transport: "mosh"
        )
        tracker.recordSuccessfulConnection(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            transport: "et"
        )

        tracker.noteTerminalSessionEnded(otherTerminalsActive: true)
        #expect(tracker.reviewRequestToken == 0)
        tracker.noteTerminalSessionEnded(otherTerminalsActive: false)

        #expect(persistence.history.successfulConnectionCount == 3)
        #expect(persistence.history.usageDayCount == 2)
        #expect(persistence.history.lastReviewRequest == clock.now)
        #expect(analytics.successfulConnectionTransports == ["ssh", "mosh", "et"])
        #expect(analytics.reviewPromptRequestCount == 1)
        #expect(tracker.reviewRequestToken == 1)
    }

    @Test
    func paywallSuppressesSessionReviewForRestOfLaunch() {
        let clock = EngagementTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let persistence = EngagementPersistenceSpy(
            history: EngagementHistory(
                successfulConnectionCount: 3,
                usageDayCount: 2,
                lastUsageDay: clock.now,
                lastReviewRequest: nil
            )
        )
        let analytics = EngagementAnalyticsSpy()
        let tracker = makeTracker(
            persistence: persistence,
            analytics: analytics,
            clock: clock
        )

        tracker.recordSuccessfulConnection(id: UUID(), transport: "ssh")
        tracker.notePaywallPresented()
        tracker.noteTerminalSessionEnded(otherTerminalsActive: false)

        #expect(tracker.reviewRequestToken == 0)
        #expect(analytics.reviewPromptRequestCount == 0)
        #expect(persistence.history.lastReviewRequest == nil)
    }

    @Test
    func inactiveApplicationDefersReviewUntilActive() {
        let clock = EngagementTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let persistence = EngagementPersistenceSpy(
            history: EngagementHistory(
                successfulConnectionCount: 3,
                usageDayCount: 2,
                lastUsageDay: clock.now,
                lastReviewRequest: nil
            )
        )
        let analytics = EngagementAnalyticsSpy()
        let applicationState = EngagementApplicationState(isActive: false)
        let tracker = makeTracker(
            persistence: persistence,
            analytics: analytics,
            clock: clock,
            applicationState: applicationState
        )

        tracker.recordSuccessfulConnection(id: UUID(), transport: "ssh")
        tracker.noteTerminalSessionEnded(otherTerminalsActive: false)
        #expect(tracker.reviewRequestToken == 0)

        applicationState.isActive = true
        tracker.noteTerminalSessionEnded(otherTerminalsActive: false)
        #expect(tracker.reviewRequestToken == 1)
    }

    @Test
    func priorLaunchConnectionsDoNotCauseSessionReview() {
        let clock = EngagementTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let persistence = EngagementPersistenceSpy(
            history: EngagementHistory(
                successfulConnectionCount: 3,
                usageDayCount: 2,
                lastUsageDay: clock.now,
                lastReviewRequest: nil
            )
        )
        let analytics = EngagementAnalyticsSpy()
        let tracker = makeTracker(
            persistence: persistence,
            analytics: analytics,
            clock: clock
        )

        tracker.noteTerminalSessionEnded(otherTerminalsActive: false)

        #expect(tracker.reviewRequestToken == 0)
        #expect(analytics.reviewPromptRequestCount == 0)
    }

    @Test
    func purchaseReviewUsesInjectedClockAndExactCooldown() {
        let previousRequest = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = EngagementTestClock(
            now: previousRequest.addingTimeInterval(60 * 60 * 24 * 59)
        )
        let persistence = EngagementPersistenceSpy(
            history: EngagementHistory(
                successfulConnectionCount: 0,
                usageDayCount: 0,
                lastUsageDay: nil,
                lastReviewRequest: previousRequest
            )
        )
        let analytics = EngagementAnalyticsSpy()
        let tracker = makeTracker(
            persistence: persistence,
            analytics: analytics,
            clock: clock
        )

        tracker.requestReviewAfterPurchase()
        #expect(tracker.reviewRequestToken == 0)

        clock.now = previousRequest.addingTimeInterval(60 * 60 * 24 * 60)
        tracker.requestReviewAfterPurchase()

        #expect(tracker.reviewRequestToken == 1)
        #expect(analytics.reviewPromptRequestCount == 1)
        #expect(persistence.history.lastReviewRequest == clock.now)
    }

    @Test
    func connectionAndDayCountersSaturateWithoutOverflow() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = EngagementTestClock(now: today)
        let persistence = EngagementPersistenceSpy(
            history: EngagementHistory(
                successfulConnectionCount: Int.max,
                usageDayCount: Int.max,
                lastUsageDay: today.addingTimeInterval(-86_400),
                lastReviewRequest: nil
            )
        )
        let tracker = makeTracker(
            persistence: persistence,
            analytics: EngagementAnalyticsSpy(),
            clock: clock
        )

        tracker.recordSuccessfulConnection(id: UUID(), transport: "ssh")

        #expect(persistence.history.successfulConnectionCount == Int.max)
        #expect(persistence.history.usageDayCount == Int.max)
    }

    private func makeTracker(
        persistence: EngagementPersistenceSpy,
        analytics: EngagementAnalyticsSpy,
        clock: EngagementTestClock,
        applicationState: EngagementApplicationState? = nil
    ) -> EngagementTracker {
        let applicationState = applicationState ?? EngagementApplicationState(isActive: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return EngagementTracker(
            dependencies: EngagementTrackerDependencies(
                persistence: persistence,
                analytics: analytics,
                now: { clock.now },
                startOfDay: { calendar.startOfDay(for: $0) },
                applicationIsActive: { applicationState.isActive }
            )
        )
    }
}

@Suite(.serialized)
@MainActor
struct UserDefaultsEngagementPersistenceTests {
    @Test
    func historyRoundTripsAndOptionalDatesCanBeCleared() {
        let suiteName = "EngagementPersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UserDefaultsEngagementPersistence(defaults: defaults)
        let history = EngagementHistory(
            successfulConnectionCount: 7,
            usageDayCount: 4,
            lastUsageDay: Date(timeIntervalSince1970: 1_700_000_000),
            lastReviewRequest: Date(timeIntervalSince1970: 1_700_000_100)
        )

        #expect(persistence.loadHistory() == .empty)
        persistence.saveHistory(history)
        #expect(persistence.loadHistory() == history)

        var historyWithoutDates = history
        historyWithoutDates.lastUsageDay = nil
        historyWithoutDates.lastReviewRequest = nil
        persistence.saveHistory(historyWithoutDates)
        #expect(persistence.loadHistory() == historyWithoutDates)
    }
}

@Suite(.serialized)
@MainActor
struct EngagementTrackerLiveDependenciesTests {
    @Test
    func liveDependenciesRouteInjectedOwnersAndFacts() {
        let suiteName = "EngagementLiveDependenciesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let history = EngagementHistory(
            successfulConnectionCount: 4,
            usageDayCount: 2,
            lastUsageDay: Date(timeIntervalSince1970: 100),
            lastReviewRequest: nil
        )
        UserDefaultsEngagementPersistence(defaults: defaults).saveHistory(history)
        let analytics = EngagementAnalyticsSpy()
        let now = Date(timeIntervalSince1970: 123_456)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let applicationState = EngagementApplicationState(isActive: true)
        let dependencies = EngagementTrackerDependencies.live(
            defaults: defaults,
            analytics: analytics,
            now: { now },
            calendar: calendar,
            applicationIsActive: { applicationState.isActive }
        )

        #expect(dependencies.persistence.loadHistory() == history)
        #expect(dependencies.analytics === analytics)
        #expect(dependencies.now() == now)
        #expect(dependencies.startOfDay(now) == calendar.startOfDay(for: now))
        #expect(dependencies.applicationIsActive())
        applicationState.isActive = false
        #expect(!dependencies.applicationIsActive())

        dependencies.analytics.trackReviewPromptRequested()
        #expect(analytics.reviewPromptRequestCount == 1)
    }
}

@MainActor
private final class EngagementPersistenceSpy: EngagementPersisting {
    var history: EngagementHistory
    private(set) var savedHistories: [EngagementHistory] = []

    init(history: EngagementHistory = .empty) {
        self.history = history
    }

    func loadHistory() -> EngagementHistory {
        history
    }

    func saveHistory(_ history: EngagementHistory) {
        self.history = history
        savedHistories.append(history)
    }
}

@MainActor
private final class EngagementAnalyticsSpy: EngagementAnalytics {
    private(set) var successfulConnectionTransports: [String] = []
    private(set) var reviewPromptRequestCount = 0

    func trackConnectionSucceeded(transport: String) {
        successfulConnectionTransports.append(transport)
    }

    func trackReviewPromptRequested() {
        reviewPromptRequestCount += 1
    }
}

@MainActor
private final class EngagementTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private final class EngagementApplicationState {
    var isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }
}
