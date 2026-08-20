import Foundation

@MainActor
enum LocalSSHDiscoveryStatusText {
    static func text(
        for phase: LocalSSHDiscoveryState.Phase,
        hostCount: Int
    ) -> String {
        switch phase {
        case .idle:
            return String(localized: "Ready to scan your local network.")
        case .unsupportedNetwork:
            return String(localized: "Connect to Wi-Fi or ethernet to discover local SSH hosts.")
        case .scanning(let scan):
            let sources = scan.activeSources
            if sources.contains(.bonjour) && sources.contains(.probe) {
                return String(localized: "Scanning with Bonjour and SSH port probe...")
            }
            if sources.contains(.bonjour) {
                return String(localized: "Scanning Bonjour services...")
            }
            if sources.contains(.probe) {
                return String(localized: "Scanning local subnet for SSH port 22...")
            }
            return String(localized: "Scanning...")
        case .completed:
            guard hostCount > 0 else {
                return String(localized: "No SSH hosts found.")
            }
            return String(
                format: String(localized: "%lld SSH host(s) found."),
                Int64(hostCount)
            )
        }
    }
}

@MainActor
extension LocalSSHDiscoveryManager {
    var statusText: String {
        LocalSSHDiscoveryStatusText.text(
            for: state.phase,
            hostCount: hosts.count
        )
    }
}
