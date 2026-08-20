import Foundation

nonisolated enum LocalSSHDiscoverySourceStatus: Sendable {
    case bonjourStarted
    case bonjourFinished
    case probeStarted
    case probeFinished
}

nonisolated enum LocalSSHDiscoveryEvent: Sendable {
    case scanningStarted
    case sourceStatus(LocalSSHDiscoverySourceStatus)
    case hostFound(DiscoveredSSHHost)
    case permissionDenied
    case scanningFinished
}

nonisolated enum LocalSSHDiscoveryNetworkAvailability: Equatable, Sendable {
    case supported
    case unsupported
}

nonisolated struct LocalSSHDiscoveryStopRequest: Sendable {
    private let stop: @MainActor @Sendable () -> Void

    init(stop: @escaping @MainActor @Sendable () -> Void) {
        self.stop = stop
    }

    func perform() {
        Task { @MainActor in
            stop()
        }
    }
}

@MainActor
protocol LocalSSHDiscovering: AnyObject {
    var ownerReleaseStopRequest: LocalSSHDiscoveryStopRequest { get }

    func startScan() -> AsyncStream<LocalSSHDiscoveryEvent>
    func stopScan()
}

@MainActor
struct LocalSSHDiscoveryDependencies {
    let service: any LocalSSHDiscovering
    let networkAvailability: () -> LocalSSHDiscoveryNetworkAvailability
    let makeScanID: () -> UUID
}
