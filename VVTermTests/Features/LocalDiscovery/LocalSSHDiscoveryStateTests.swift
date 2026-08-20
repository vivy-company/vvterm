import Foundation
import Testing
@testable import VVTerm

@MainActor
struct LocalSSHDiscoveryStateTests {
    @Test
    func liveDependenciesUseInjectedNetworkStateAndScanID() {
        let scanID = UUID()
        var connectionType = NetworkMonitor.ConnectionType.cellular
        let dependencies = LocalSSHDiscoveryDependencies.live(
            networkConnectionType: { connectionType },
            makeScanID: { scanID }
        )

        #expect(dependencies.networkAvailability() == .unsupported)
        connectionType = .wifi
        #expect(dependencies.networkAvailability() == .supported)
        connectionType = .ethernet
        #expect(dependencies.networkAvailability() == .supported)
        connectionType = .unknown
        #expect(dependencies.networkAvailability() == .supported)
        #expect(dependencies.makeScanID() == scanID)
    }

    @Test
    func activeSourcesArePartOfTheScanningState() {
        var state = LocalSSHDiscoveryState()
        let scanID = UUID()

        state.start(id: scanID)
        state.handle(.sourceStatus(.bonjourStarted), scanID: scanID)
        state.handle(.sourceStatus(.probeStarted), scanID: scanID)

        #expect(state.isScanning)
        #expect(state.isSourceActive(.bonjour))
        #expect(state.isSourceActive(.probe))

        state.handle(.sourceStatus(.bonjourFinished), scanID: scanID)

        #expect(!state.isSourceActive(.bonjour))
        #expect(state.isSourceActive(.probe))
    }

    @Test
    func staleCompletionCannotFinishANewerScan() {
        var state = LocalSSHDiscoveryState()
        let oldScanID = UUID()
        let newScanID = UUID()

        state.start(id: oldScanID)
        state.start(id: newScanID)

        let acceptedStaleCompletion = state.handle(.scanningFinished, scanID: oldScanID)

        #expect(!acceptedStaleCompletion)
        #expect(state.isScanning)

        let acceptedCurrentCompletion = state.handle(.scanningFinished, scanID: newScanID)

        #expect(acceptedCurrentCompletion)
        #expect(!state.isScanning)
        #expect(state.phase == .completed(.unknown))
    }

    @Test
    func permissionDenialRemainsVisibleAfterTheServiceFinishes() {
        var state = LocalSSHDiscoveryState()
        let scanID = UUID()

        state.start(id: scanID)
        state.handle(.permissionDenied, scanID: scanID)
        state.handle(.scanningFinished, scanID: scanID)

        #expect(!state.isScanning)
        #expect(state.phase == .completed(.denied))
        #expect(state.permission == .denied)
    }

    @Test
    func stoppingAScanClearsItsActiveSources() {
        var state = LocalSSHDiscoveryState()
        let scanID = UUID()

        state.start(id: scanID)
        state.handle(.sourceStatus(.bonjourStarted), scanID: scanID)
        state.stop(clearResults: false)

        #expect(!state.isScanning)
        #expect(!state.isSourceActive(.bonjour))
        #expect(state.phase == .completed(.unknown))
    }

    @Test
    func unsupportedNetworkDoesNotStartTheDiscoveryService() {
        let service = LocalSSHDiscoveringFake()
        let manager = LocalSSHDiscoveryManager(
            dependencies: LocalSSHDiscoveryDependencies(
                service: service,
                networkAvailability: { .unsupported },
                makeScanID: UUID.init
            )
        )

        manager.startScan()

        #expect(manager.state.phase == .unsupportedNetwork)
        #expect(manager.hosts.isEmpty)
        #expect(service.startCount == 0)
        #expect(service.stopCount == 1)
    }

    @Test
    func supportedNetworkStartsAndStopsTheOwnedScan() {
        let service = LocalSSHDiscoveringFake()
        let scanID = UUID()
        let manager = LocalSSHDiscoveryManager(
            dependencies: LocalSSHDiscoveryDependencies(
                service: service,
                networkAvailability: { .supported },
                makeScanID: { scanID }
            )
        )

        manager.startScan()

        #expect(
            manager.state.phase
                == .scanning(LocalSSHDiscoveryState.Scan(id: scanID))
        )
        #expect(service.startCount == 1)
        #expect(service.stopCount == 1)

        manager.stopScan(clearResults: true)

        #expect(manager.state.phase == .idle)
        #expect(service.stopCount == 2)
    }

    @Test
    func ownerReleaseCancelsAnOpenDiscoveryStream() async {
        let service = LocalSSHDiscoveringFake()
        var manager: LocalSSHDiscoveryManager? = LocalSSHDiscoveryManager(
            dependencies: LocalSSHDiscoveryDependencies(
                service: service,
                networkAvailability: { .supported },
                makeScanID: UUID.init
            )
        )
        weak var weakManager: LocalSSHDiscoveryManager?
        weakManager = manager

        manager?.startScan()
        manager = nil
        #expect(await waitUntil {
            service.stopCount == 2 && service.terminationCount == 1
        })

        #expect(weakManager == nil)
        #expect(service.stopCount == 2)
        #expect(service.terminationCount == 1)
    }

    @Test
    func unsupportedRescanStopsTheActiveServiceBeforeRejectingTheNetwork() {
        let service = LocalSSHDiscoveringFake()
        var availability = LocalSSHDiscoveryNetworkAvailability.supported
        let manager = LocalSSHDiscoveryManager(
            dependencies: LocalSSHDiscoveryDependencies(
                service: service,
                networkAvailability: { availability },
                makeScanID: UUID.init
            )
        )

        manager.startScan()
        availability = .unsupported
        manager.rescan()

        #expect(manager.state.phase == .unsupportedNetwork)
        #expect(service.startCount == 1)
        #expect(service.stopCount == 2)
    }

    @Test
    func canceledOldStreamCannotChangeAReplacementScan() async {
        let service = LocalSSHDiscoveringFake(finishesStreamOnStop: false)
        let oldScanID = UUID()
        let newScanID = UUID()
        var scanIDs = [oldScanID, newScanID]
        let manager = LocalSSHDiscoveryManager(
            dependencies: LocalSSHDiscoveryDependencies(
                service: service,
                networkAvailability: { .supported },
                makeScanID: { scanIDs.removeFirst() }
            )
        )

        manager.startScan()
        manager.rescan()
        service.yield(.hostFound(makeHost(name: "Old")), toStreamAt: 0)
        service.yield(.scanningFinished, toStreamAt: 0)
        for _ in 0..<10 { await Task.yield() }

        #expect(manager.hosts.isEmpty)
        #expect(manager.state.phase == .scanning(LocalSSHDiscoveryState.Scan(id: newScanID)))

        service.yield(.hostFound(makeHost(name: "New")), toStreamAt: 1)
        #expect(await waitUntil { manager.hosts.map(\.displayName) == ["New"] })
    }

    private func makeHost(name: String) -> DiscoveredSSHHost {
        DiscoveredSSHHost(
            displayName: name,
            host: "\(name.lowercased()).local",
            port: 22,
            sources: [.bonjour]
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class LocalSSHDiscoveringFake: LocalSSHDiscovering {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var terminationCount = 0
    private let finishesStreamOnStop: Bool
    private var continuations: [AsyncStream<LocalSSHDiscoveryEvent>.Continuation] = []
    private var activeStreamIndex: Int?

    init(finishesStreamOnStop: Bool = true) {
        self.finishesStreamOnStop = finishesStreamOnStop
    }

    var ownerReleaseStopRequest: LocalSSHDiscoveryStopRequest {
        LocalSSHDiscoveryStopRequest {
            self.stopScan()
        }
    }

    func startScan() -> AsyncStream<LocalSSHDiscoveryEvent> {
        startCount += 1
        return AsyncStream { continuation in
            let index = continuations.count
            let termination = LocalSSHDiscoveryStopRequest { [weak self] in
                self?.terminationCount += 1
            }
            continuation.onTermination = { _ in
                termination.perform()
            }
            continuations.append(continuation)
            activeStreamIndex = index
        }
    }

    func stopScan() {
        stopCount += 1
        guard let activeStreamIndex else { return }
        self.activeStreamIndex = nil
        if finishesStreamOnStop {
            continuations[activeStreamIndex].finish()
        }
    }

    func yield(_ event: LocalSSHDiscoveryEvent, toStreamAt index: Int) {
        continuations[index].yield(event)
    }
}
