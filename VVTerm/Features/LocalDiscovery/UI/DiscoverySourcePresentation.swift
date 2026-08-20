import Foundation

extension DiscoverySource {
    var label: String {
        switch self {
        case .bonjour:
            return String(localized: "Bonjour")
        case .portScan:
            return String(localized: "Port Scan")
        }
    }
}
