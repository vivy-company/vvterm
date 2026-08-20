nonisolated extension ConnectionViewTabID {
    var localizedKey: String {
        switch self {
        case .stats: "Stats"
        case .terminal: "Terminal"
        case .files: "Files"
        }
    }

    var icon: String {
        switch self {
        case .stats: "chart.bar.xaxis"
        case .terminal: "terminal"
        case .files: "folder"
        }
    }
}
