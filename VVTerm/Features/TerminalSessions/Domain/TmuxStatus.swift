nonisolated enum TmuxStatus: String, Codable, Hashable, Sendable {
    case foreground
    case background
    case off
    case missing
    case installing
    case unknown

    var indicatesTmux: Bool {
        switch self {
        case .foreground, .background, .unknown:
            return true
        case .off, .missing, .installing:
            return false
        }
    }
}
