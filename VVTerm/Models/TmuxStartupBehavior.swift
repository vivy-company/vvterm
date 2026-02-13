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
}
