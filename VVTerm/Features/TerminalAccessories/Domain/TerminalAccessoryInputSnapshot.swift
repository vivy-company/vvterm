import Foundation

nonisolated enum TerminalAccessoryResolvedItem: Equatable, Sendable {
    case system(TerminalAccessorySystemActionID)
    case custom(TerminalAccessoryCustomAction)
}

nonisolated enum TerminalAccessoryInputSnapshotChange: Equatable, Sendable {
    case none
    case leadingButtons
    case itemsAndLeadingButtons
}

nonisolated struct TerminalAccessoryInputSnapshot: Equatable, Sendable {
    let resolvedItems: [TerminalAccessoryResolvedItem]
    let showsDismissKeyboardButton: Bool

    init(
        profile: TerminalAccessoryProfile,
        showsDismissKeyboardButton: Bool
    ) {
        var customActionsByID: [UUID: TerminalAccessoryCustomAction] = [:]
        for action in profile.customActions where !action.isDeleted {
            customActionsByID[action.id] = action
        }
        resolvedItems = profile.layout.activeItems.compactMap { item in
            switch item {
            case .system(let actionID):
                return .system(actionID)
            case .custom(let actionID):
                guard let action = customActionsByID[actionID] else { return nil }
                return .custom(action)
            }
        }
        self.showsDismissKeyboardButton = showsDismissKeyboardButton
    }

    func change(from current: Self) -> TerminalAccessoryInputSnapshotChange {
        if resolvedItems != current.resolvedItems {
            return .itemsAndLeadingButtons
        }
        if showsDismissKeyboardButton != current.showsDismissKeyboardButton {
            return .leadingButtons
        }
        return .none
    }
}
