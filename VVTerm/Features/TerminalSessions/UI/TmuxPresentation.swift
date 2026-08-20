import Foundation

extension TmuxStartupBehavior {
    var displayName: String {
        switch self {
        case .vvtermManaged:
            return String(localized: "Create VVTerm session")
        case .askEveryTime:
            return String(localized: "Ask every time")
        case .skipTmux:
            return String(localized: "Skip tmux")
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
        }
    }
}

extension TmuxStatus {
    var shortLabel: String {
        switch self {
        case .foreground: return "tmux"
        case .background: return "tmux"
        case .off: return "off"
        case .missing: return "tmux missing"
        case .installing: return "tmux install"
        case .unknown: return "tmux"
        }
    }

    var displayName: String {
        switch self {
        case .foreground: return "Foreground"
        case .background: return "Background"
        case .off: return "Off"
        case .missing: return "No tmux"
        case .installing: return "Installing"
        case .unknown: return "Unknown"
        }
    }
}
