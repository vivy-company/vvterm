import Foundation

extension TerminalAccessoryValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .customActionLimitReached:
            return String(
                format: String(localized: "You can create up to %lld custom actions."),
                Int64(TerminalAccessoryProfile.maxCustomActions)
            )
        case .customActionProRequired:
            return String(
                format: String(localized: "The free plan includes %lld custom actions. Upgrade to Pro for unlimited custom actions."),
                Int64(FreeTierLimits.maxCustomActions)
            )
        case .emptyTitle:
            return String(localized: "Action title cannot be empty.")
        case .emptyCommandContent:
            return String(localized: "Command content cannot be empty.")
        case .customActionNotFound:
            return String(localized: "Action not found.")
        }
    }
}
