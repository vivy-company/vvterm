import Foundation

nonisolated enum SSHKeepAlivePolicy: Equatable, Sendable {
    case disabled
    case enabled(intervalSeconds: Int)
}

nonisolated struct SSHRuntimeSettings: Equatable, Sendable {
    static let keepAliveEnabledKey = "sshKeepAliveEnabled"
    static let keepAliveIntervalKey = "sshKeepAliveInterval"
    static let defaultKeepAliveIntervalSeconds = 30
    static let keepAliveIntervalRange = 10...120

    let keepAlive: SSHKeepAlivePolicy

    init(keepAliveEnabled: Bool, keepAliveIntervalSeconds: Int) {
        guard keepAliveEnabled else {
            keepAlive = .disabled
            return
        }

        keepAlive = .enabled(
            intervalSeconds: min(
                max(keepAliveIntervalSeconds, Self.keepAliveIntervalRange.lowerBound),
                Self.keepAliveIntervalRange.upperBound
            )
        )
    }

    init(defaults: UserDefaults) {
        let keepAliveEnabled = (defaults.object(forKey: Self.keepAliveEnabledKey) as? NSNumber)?
            .boolValue ?? true
        let storedInterval = (defaults.object(forKey: Self.keepAliveIntervalKey) as? NSNumber)?
            .intValue ?? Self.defaultKeepAliveIntervalSeconds

        self.init(
            keepAliveEnabled: keepAliveEnabled,
            keepAliveIntervalSeconds: storedInterval
        )
    }
}
