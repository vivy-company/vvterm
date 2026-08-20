import Foundation
import Combine

struct LocalSSHDiscoveryState: Equatable {
    enum Permission: Equatable {
        case unknown
        case granted
        case denied
    }

    struct Scan: Equatable {
        enum Source: Hashable {
            case bonjour
            case probe
        }

        let id: UUID
        var activeSources: Set<Source> = []
        var permission: Permission = .unknown
    }

    enum Phase: Equatable {
        case idle
        case scanning(Scan)
        case completed(Permission)
        case unsupportedNetwork
    }

    private(set) var phase: Phase = .idle

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var permission: Permission {
        switch phase {
        case .scanning(let scan):
            return scan.permission
        case .completed(let permission):
            return permission
        case .idle, .unsupportedNetwork:
            return .unknown
        }
    }

    func isSourceActive(_ source: Scan.Source) -> Bool {
        guard case .scanning(let scan) = phase else { return false }
        return scan.activeSources.contains(source)
    }

    mutating func start(id: UUID) {
        phase = .scanning(Scan(id: id))
    }

    mutating func rejectUnsupportedNetwork() {
        phase = .unsupportedNetwork
    }

    mutating func stop(clearResults: Bool) {
        guard !clearResults else {
            phase = .idle
            return
        }

        if case .scanning(let scan) = phase {
            phase = .completed(scan.permission)
        }
    }

    @discardableResult
    mutating func handle(_ event: LocalSSHDiscoveryEvent, scanID: UUID) -> Bool {
        switch phase {
        case .scanning(var scan) where scan.id == scanID:
            switch event {
            case .scanningStarted:
                return true
            case .sourceStatus(let status):
                switch status {
                case .bonjourStarted:
                    scan.activeSources.insert(.bonjour)
                case .bonjourFinished:
                    scan.activeSources.remove(.bonjour)
                case .probeStarted:
                    scan.activeSources.insert(.probe)
                case .probeFinished:
                    scan.activeSources.remove(.probe)
                }
                phase = .scanning(scan)
            case .hostFound:
                scan.permission = .granted
                phase = .scanning(scan)
            case .permissionDenied:
                scan.permission = .denied
                phase = .scanning(scan)
            case .scanningFinished:
                phase = .completed(scan.permission)
            }
            return true
        case .idle, .completed, .unsupportedNetwork, .scanning:
            return false
        }
    }
}

@MainActor
final class LocalSSHDiscoveryManager: ObservableObject {
    @Published private(set) var hosts: [DiscoveredSSHHost] = []
    @Published private(set) var state = LocalSSHDiscoveryState()

    private let dependencies: LocalSSHDiscoveryDependencies
    private let ownerReleaseStopRequest: LocalSSHDiscoveryStopRequest
    private var streamTask: Task<Void, Never>?
    private let maxHosts = 200

    init(dependencies: LocalSSHDiscoveryDependencies) {
        self.dependencies = dependencies
        self.ownerReleaseStopRequest = dependencies.service.ownerReleaseStopRequest
    }

    deinit {
        streamTask?.cancel()
        ownerReleaseStopRequest.perform()
    }

    var isScanning: Bool { state.isScanning }
    var permissionState: LocalSSHDiscoveryState.Permission { state.permission }
    var bonjourActive: Bool { state.isSourceActive(.bonjour) }
    var probeActive: Bool { state.isSourceActive(.probe) }

    func startScan() {
        stopScan(clearResults: false)

        guard dependencies.networkAvailability() == .supported else {
            state.rejectUnsupportedNetwork()
            hosts = []
            return
        }

        hosts = []
        let scanID = dependencies.makeScanID()
        state.start(id: scanID)

        let stream = dependencies.service.startScan()
        streamTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.handleEvent(event, scanID: scanID)
            }
        }
    }

    func rescan() {
        startScan()
    }

    func stopScan(clearResults: Bool = false) {
        streamTask?.cancel()
        streamTask = nil
        dependencies.service.stopScan()
        state.stop(clearResults: clearResults)
        if clearResults {
            hosts = []
        }
    }

    private func handleEvent(_ event: LocalSSHDiscoveryEvent, scanID: UUID) {
        guard state.handle(event, scanID: scanID) else { return }

        switch event {
        case .hostFound(let discovered):
            upsert(discovered)
        case .scanningStarted, .sourceStatus, .permissionDenied, .scanningFinished:
            break
        }
    }

    private func upsert(_ host: DiscoveredSSHHost) {
        guard !host.host.isEmpty else { return }

        if let existingIndex = hosts.firstIndex(where: { $0.id == host.id }) {
            var merged = hosts[existingIndex]
            merged.merge(with: host)
            hosts[existingIndex] = merged
        } else {
            guard hosts.count < maxHosts else { return }
            hosts.append(host)
        }

        hosts.sort { lhs, rhs in
            let lhsBonjour = lhs.sources.contains(.bonjour)
            let rhsBonjour = rhs.sources.contains(.bonjour)
            if lhsBonjour != rhsBonjour {
                return lhsBonjour && !rhsBonjour
            }

            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
        }
    }
}
