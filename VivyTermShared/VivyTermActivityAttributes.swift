import Foundation

#if os(iOS)
import ActivityKit

@available(iOS 16.1, *)
enum VivyTermLiveActivityStatus: String, Codable, Hashable {
    case connected
    case connecting
    case reconnecting
    case disconnected

    var label: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .reconnecting:
            return "Reconnecting"
        case .disconnected:
            return "Disconnected"
        }
    }
}

@available(iOS 16.1, *)
struct VivyTermActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: VivyTermLiveActivityStatus
        var activeCount: Int
    }

    var appName: String
}
#endif
