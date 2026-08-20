nonisolated struct TerminalLiveActivitySnapshot: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        case connected
        case connecting
        case reconnecting
    }

    let status: Status
    let activeCount: Int
}

nonisolated enum TerminalLiveActivityPolicy {
    static func snapshot(for connectionStates: [ConnectionState]) -> TerminalLiveActivitySnapshot? {
        let activeStates = connectionStates.filter { $0.isConnected || $0.isConnecting }
        guard !activeStates.isEmpty else { return nil }

        let status: TerminalLiveActivitySnapshot.Status
        if activeStates.contains(where: { state in
            if case .reconnecting = state { return true }
            return false
        }) {
            status = .reconnecting
        } else if activeStates.contains(where: { state in
            if case .connecting = state { return true }
            return false
        }) {
            status = .connecting
        } else {
            status = .connected
        }

        return TerminalLiveActivitySnapshot(
            status: status,
            activeCount: activeStates.count
        )
    }
}
