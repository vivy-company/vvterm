import Foundation

nonisolated struct EngagementHistory: Equatable, Sendable {
    static let empty = EngagementHistory(
        successfulConnectionCount: 0,
        usageDayCount: 0,
        lastUsageDay: nil,
        lastReviewRequest: nil
    )

    var successfulConnectionCount: Int
    var usageDayCount: Int
    var lastUsageDay: Date?
    var lastReviewRequest: Date?
}

@MainActor
protocol EngagementPersisting: AnyObject {
    func loadHistory() -> EngagementHistory
    func saveHistory(_ history: EngagementHistory)
}

@MainActor
protocol EngagementAnalytics: AnyObject {
    func trackConnectionSucceeded(transport: String)
    func trackReviewPromptRequested()
}

@MainActor
struct EngagementTrackerDependencies {
    let persistence: any EngagementPersisting
    let analytics: any EngagementAnalytics
    let now: () -> Date
    let startOfDay: (Date) -> Date
    let applicationIsActive: @MainActor @Sendable () -> Bool
}
