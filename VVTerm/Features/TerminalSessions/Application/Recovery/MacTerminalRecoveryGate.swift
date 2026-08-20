#if os(macOS)
import Foundation

nonisolated struct MacTerminalRecoveryGate {
    private enum State {
        case idle
        case sleeping(UUID)
        case waitingForNetwork(UUID)
        case recovering(UUID)
    }

    enum Signal: Sendable {
        case sleep
        case wake
        case applicationActivated
        case networkChanged(TerminalNetworkReadiness)
    }

    enum Action: Equatable, Sendable {
        case none
        case waitForNetwork(UUID)
        case recover(UUID)
    }

    private var state = State.idle

    var recoveringGeneration: UUID? {
        guard case .recovering(let generation) = state else { return nil }
        return generation
    }

    mutating func receive(
        _ signal: Signal,
        networkReadiness: TerminalNetworkReadiness
    ) -> Action {
        switch signal {
        case .sleep:
            if case .sleeping = state {
                return .none
            } else {
                state = .sleeping(UUID())
            }
            return .none

        case .wake, .applicationActivated:
            switch state {
            case .idle:
                return .none
            case .sleeping(let cycleID), .waitingForNetwork(let cycleID):
                return recoveryAction(
                    cycleID: cycleID,
                    networkReadiness: networkReadiness
                )
            case .recovering:
                return .none
            }

        case .networkChanged(let readiness):
            switch state {
            case .waitingForNetwork(let cycleID):
                return recoveryAction(cycleID: cycleID, networkReadiness: readiness)
            case .recovering(let cycleID) where readiness != .ready:
                state = .waitingForNetwork(cycleID)
                return .waitForNetwork(cycleID)
            case .idle, .sleeping, .recovering:
                return .none
            }
        }
    }

    mutating func complete(_ cycleID: UUID) {
        guard case .recovering(let activeCycleID) = state,
              activeCycleID == cycleID else { return }
        state = .idle
    }

    private mutating func recoveryAction(
        cycleID: UUID,
        networkReadiness: TerminalNetworkReadiness
    ) -> Action {
        guard networkReadiness == .ready else {
            guard case .sleeping = state else { return .none }
            state = .waitingForNetwork(cycleID)
            return .waitForNetwork(cycleID)
        }

        state = .recovering(cycleID)
        return .recover(cycleID)
    }
}

enum MacTerminalRecoveryPolicy {
    enum ReadyStrategy: Equatable, Sendable {
        case ignore
        case verifyOrReplace
        case allowEternalTerminalSelfRecovery
    }

    static func shouldPrepareWhileOffline(
        connectionState: ConnectionState,
        hasEstablishedConnection: Bool
    ) -> Bool {
        switch connectionState {
        case .connecting, .reconnecting:
            return true
        case .disconnected, .failed:
            return hasEstablishedConnection
        case .connected, .idle:
            return false
        }
    }

    static func readyStrategy(
        connectionState: ConnectionState,
        hasEstablishedConnection: Bool,
        activeTransport: ShellTransport,
        hasEternalTerminalRuntime: Bool
    ) -> ReadyStrategy {
        guard connectionState.isConnecting || hasEstablishedConnection else {
            return .ignore
        }
        if activeTransport == .eternalTerminal,
           hasEternalTerminalRuntime {
            return .allowEternalTerminalSelfRecovery
        }
        return .verifyOrReplace
    }

    static func hasVerifiedLiveTransport(
        connectionState: ConnectionState,
        activeTransport: ShellTransport,
        hasEternalTerminalRuntime: Bool,
        hasShellOwnership: Bool,
        transportIsLive: Bool
    ) -> Bool {
        if activeTransport == .eternalTerminal {
            return hasEternalTerminalRuntime
                && connectionState.isConnected
                && transportIsLive
        }
        guard hasShellOwnership, transportIsLive else { return false }
        return connectionState.isConnected
            || (activeTransport == .mosh && connectionState.isConnecting)
    }
}
#endif
