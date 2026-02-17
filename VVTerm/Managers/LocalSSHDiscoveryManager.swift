import Foundation
import SwiftUI
import Combine

@MainActor
final class LocalSSHDiscoveryManager: ObservableObject {
    enum ScanState: Equatable {
        case idle
        case scanning
        case completed
        case unsupportedNetwork
        case failed(String)
    }

    enum PermissionState: Equatable {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var hosts: [DiscoveredSSHHost] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var error: String?
    @Published private(set) var bonjourActive = false
    @Published private(set) var probeActive = false

    private let service: LocalSSHDiscoveryService
    private var streamTask: Task<Void, Never>?
    private let maxHosts = 200

    init(service: LocalSSHDiscoveryService? = nil) {
        self.service = service ?? LocalSSHDiscoveryService()
    }

    deinit {
        streamTask?.cancel()
    }

    func startScan() {
        guard NetworkMonitor.shared.connectionType != .cellular else {
            isScanning = false
            scanState = .unsupportedNetwork
            error = nil
            hosts = []
            bonjourActive = false
            probeActive = false
            return
        }

        stopScan(clearResults: false)

        hosts = []
        error = nil
        isScanning = true
        scanState = .scanning
        permissionState = .unknown
        bonjourActive = false
        probeActive = false

        let stream = service.startScan()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                self.handleEvent(event)
            }
        }
    }

    func rescan() {
        startScan()
    }

    func stopScan(clearResults: Bool = false) {
        streamTask?.cancel()
        streamTask = nil
        service.stopScan()
        isScanning = false
        bonjourActive = false
        probeActive = false
        if clearResults {
            hosts = []
            error = nil
            scanState = .idle
            permissionState = .unknown
        }
    }

    var statusText: String {
        switch scanState {
        case .idle:
            return String(localized: "Ready to scan your local network.")
        case .unsupportedNetwork:
            return String(localized: "Connect to Wi-Fi or ethernet to discover local SSH hosts.")
        case .scanning:
            if bonjourActive && probeActive {
                return String(localized: "Scanning with Bonjour and SSH port probe...")
            }
            if bonjourActive {
                return String(localized: "Scanning Bonjour services...")
            }
            if probeActive {
                return String(localized: "Scanning local subnet for SSH port 22...")
            }
            return String(localized: "Scanning...")
        case .completed:
            if hosts.isEmpty {
                return String(localized: "No SSH hosts found.")
            }
            return String(
                format: String(localized: "%lld SSH host(s) found."),
                Int64(hosts.count)
            )
        case .failed(let message):
            return message
        }
    }

    private func handleEvent(_ event: LocalSSHDiscoveryEvent) {
        switch event {
        case .scanningStarted:
            isScanning = true
            scanState = .scanning
        case .sourceStatus(let status):
            switch status {
            case .bonjourStarted:
                bonjourActive = true
            case .bonjourFinished:
                bonjourActive = false
            case .probeStarted:
                probeActive = true
            case .probeFinished:
                probeActive = false
            }
        case .hostFound(let discovered):
            permissionState = .granted
            upsert(discovered)
        case .permissionDenied:
            permissionState = .denied
        case .failed(let message):
            error = message
            scanState = .failed(message)
        case .scanningFinished:
            isScanning = false
            bonjourActive = false
            probeActive = false
            if case .failed = scanState {
                return
            }
            if scanState != .unsupportedNetwork {
                scanState = .completed
            }
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
