nonisolated enum TmuxStartupBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Current behavior: always attach to a VVTerm-managed tmux session.
    case vvtermManaged
    /// Ask user on each new connection.
    case askEveryTime
    /// Start shell without tmux.
    case skipTmux

    var id: String { rawValue }

    static var configCases: [Self] { allCases }
}
