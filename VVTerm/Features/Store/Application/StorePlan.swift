import Foundation

nonisolated enum ProPlanKind: String, Identifiable, Equatable, Sendable {
    case monthly
    case yearly
    case lifetime

    static let displayOrder: [ProPlanKind] = [.monthly, .yearly, .lifetime]

    var id: String { rawValue }
}

nonisolated enum ProPlanIntroductoryOfferState: Equatable, Sendable {
    case unavailable
    case ineligible
    case eligibleForSevenDayFreeTrial
}
