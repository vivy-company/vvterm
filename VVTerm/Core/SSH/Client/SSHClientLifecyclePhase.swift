extension SSHClient {
    enum LifecyclePhase: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case failed
        case aborted
    }
}
