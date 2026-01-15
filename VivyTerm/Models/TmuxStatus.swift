import Foundation

enum TmuxStatus: String, Codable, Hashable {
    case foreground
    case background
    case off
    case missing
    case installing
    case unknown

    var shortLabel: String {
        switch self {
        case .foreground: return "tmux"
        case .background: return "tmux"
        case .off: return "off"
        case .missing: return "tmux missing"
        case .installing: return "tmux install"
        case .unknown: return ""
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
