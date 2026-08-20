import Foundation

extension DockerAvailability {
    var message: String {
        switch self {
        case .unknown:
            return String(localized: "Waiting for Docker")
        case .available:
            return ""
        case .commandMissing:
            return String(localized: "Docker command not found")
        case .daemonUnavailable(let message),
             .permissionDenied(let message),
             .unavailable(let message):
            return message
        }
    }
}
