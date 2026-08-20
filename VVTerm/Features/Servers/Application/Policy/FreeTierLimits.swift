import Foundation

nonisolated enum FreeTierLimits {
    static let maxWorkspaces = 1
    static let currentMaxServers = 1
    static let legacyMaxServers = 3
    static let maxTabs = 1
    static let maxCustomActions = 3
    static let planGenerationStorageKey = "freePlanGeneration"
    static let currentOneServerPlanCutoff: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 6
        components.day = 25
        return components.date ?? Date(timeIntervalSince1970: 1_782_345_600)
    }()
}
