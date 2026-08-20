import Foundation

nonisolated enum TerminalAutoReconnectPolicy {
    static func shouldScheduleRetry(
        automaticReconnectAllowed: Bool,
        hasEstablishedConnection: Bool,
        connectionState: ConnectionState
    ) -> Bool {
        guard automaticReconnectAllowed, hasEstablishedConnection else { return false }
        if case .failed = connectionState {
            return true
        }
        return false
    }

    static func shouldAttempt(
        sceneIsActive: Bool,
        applicationIsActive: Bool,
        appIsLocked: Bool,
        networkReadiness: TerminalNetworkReadiness,
        automaticReconnectAllowed: Bool,
        reconnectInFlight: Bool,
        hasEstablishedConnection: Bool,
        connectionState: ConnectionState
    ) -> Bool {
        let isRecoverableState: Bool
        switch connectionState {
        case .disconnected, .failed:
            isRecoverableState = true
        case .idle, .connecting, .reconnecting, .connected:
            isRecoverableState = false
        }

        return sceneIsActive
            && applicationIsActive
            && !appIsLocked
            && networkReadiness == .ready
            && automaticReconnectAllowed
            && !reconnectInFlight
            && hasEstablishedConnection
            && isRecoverableState
    }
}
