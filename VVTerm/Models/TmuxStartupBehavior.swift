import Foundation

enum TmuxStartupBehavior: String, Codable, CaseIterable, Identifiable {
    /// Current behavior: always attach to a VVTerm-managed tmux session.
    case vvtermManaged
    /// Ask user on each new connection.
    case askEveryTime
    /// Start shell without tmux.
    case skipTmux
    /// Attach to a remembered tmux session name.
    case rememberedSession

    var id: String { rawValue }

    static let globalConfigCases: [TmuxStartupBehavior] = [.vvtermManaged, .askEveryTime, .skipTmux]
    static let serverConfigCases: [TmuxStartupBehavior] = [.vvtermManaged, .askEveryTime, .skipTmux, .rememberedSession]

    var displayName: String {
        switch self {
        case .vvtermManaged:
            return String(localized: "Create VVTerm session")
        case .askEveryTime:
            return String(localized: "Ask every time")
        case .skipTmux:
            return String(localized: "Skip tmux")
        case .rememberedSession:
            return String(localized: "Use remembered session")
        }
    }

    var descriptionText: String {
        switch self {
        case .vvtermManaged:
            return String(localized: "Always create or attach to a VVTerm-managed tmux session for this connection.")
        case .askEveryTime:
            return String(localized: "Show a prompt on each new tab or split so you can choose a session.")
        case .skipTmux:
            return String(localized: "Start a normal shell without tmux session persistence.")
        case .rememberedSession:
            return String(localized: "Automatically attach to the last tmux session you selected.")
        }
    }
}
