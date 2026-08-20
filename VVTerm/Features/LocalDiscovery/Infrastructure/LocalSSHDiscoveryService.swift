import Foundation
import Network
import Darwin

@MainActor
final class LocalSSHDiscoveryService: NSObject {
    private let bonjourTypes = ["_ssh._tcp.", "_sftp-ssh._tcp."]
    private let scanDuration: TimeInterval = 6
    private let serviceResolveTimeout: TimeInterval = 2
    private let portScanTimeout: TimeInterval = 0.35
    private let portScanConcurrency = 24

    private var streamContinuation: AsyncStream<LocalSSHDiscoveryEvent>.Continuation?
    private var browsers: [NetServiceBrowser] = []
    private var servicesByName: [String: NetService] = [:]
    private var seenServices: Set<String> = []
    private var probeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var runOwnership = LocalSSHDiscoveryRunOwnership()
    private var browserRunIDs: [ObjectIdentifier: UUID] = [:]
    private var serviceRunIDs: [ObjectIdentifier: UUID] = [:]
    private let makeRunID: () -> UUID

    init(makeRunID: @escaping () -> UUID = UUID.init) {
        self.makeRunID = makeRunID
        super.init()
    }

    var ownerReleaseStopRequest: LocalSSHDiscoveryStopRequest {
        LocalSSHDiscoveryStopRequest {
            self.stopScan()
        }
    }

    func startScan() -> AsyncStream<LocalSSHDiscoveryEvent> {
        stopScan()
        let runID = makeRunID()

        return AsyncStream { continuation in
            runOwnership.start(runID: runID)
            streamContinuation = continuation
            let terminationStopRequest = LocalSSHDiscoveryStopRequest { [weak self] in
                self?.stopScan(runID: runID)
            }
            continuation.onTermination = { _ in
                terminationStopRequest.perform()
            }

            continuation.yield(.scanningStarted)
            startBonjourBrowsing(runID: runID)
            startPortScanning(runID: runID)
            startTimeoutTimer(runID: runID)
        }
    }

    func stopScan() {
        guard let runID = runOwnership.activeRunID else { return }
        stopScan(runID: runID)
    }

    private func stopScan(runID: UUID) {
        guard runOwnership.stop(runID: runID) else { return }

        timeoutTask?.cancel()
        timeoutTask = nil

        probeTask?.cancel()
        probeTask = nil

        for browser in browsers {
            browser.delegate = nil
            browser.stop()
        }
        browsers.removeAll()
        browserRunIDs.removeAll()

        for service in servicesByName.values {
            service.delegate = nil
            service.stop()
        }
        servicesByName.removeAll()
        serviceRunIDs.removeAll()
        seenServices.removeAll()

        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func startTimeoutTimer(runID: UUID) {
        let duration = scanDuration
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finishScan(runID: runID)
        }
    }

    private func finishScan(runID: UUID) {
        guard runOwnership.owns(runID: runID) else { return }
        emit(.sourceStatus(.bonjourFinished), runID: runID)
        emit(.sourceStatus(.probeFinished), runID: runID)
        emit(.scanningFinished, runID: runID)
        stopScan(runID: runID)
    }

    private func emit(_ event: LocalSSHDiscoveryEvent, runID: UUID) {
        guard runOwnership.owns(runID: runID) else { return }
        streamContinuation?.yield(event)
    }

    private func startBonjourBrowsing(runID: UUID) {
        emit(.sourceStatus(.bonjourStarted), runID: runID)
        for serviceType in bonjourTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browserRunIDs[ObjectIdentifier(browser)] = runID
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
        }
    }

    private func startPortScanning(runID: UUID) {
        emit(.sourceStatus(.probeStarted), runID: runID)

        let timeout = portScanTimeout
        let concurrency = max(1, portScanConcurrency)

        probeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let candidates = Self.localSubnetCandidates()

            guard !candidates.isEmpty else {
                emit(.sourceStatus(.probeFinished), runID: runID)
                return
            }

            var startIndex = 0
            while startIndex < candidates.count {
                if Task.isCancelled {
                    break
                }

                let endIndex = min(startIndex + concurrency, candidates.count)
                let chunk = Array(candidates[startIndex..<endIndex])

                await withTaskGroup(of: (host: String, latencyMs: Int)?.self) { group in
                    for host in chunk {
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            return await Self.probeSSHHost(host, timeout: timeout)
                        }
                    }

                    for await result in group {
                        guard let found = result else { continue }
                        let discovered = DiscoveredSSHHost(
                            displayName: found.host,
                            host: found.host,
                            port: 22,
                            sources: [.portScan],
                            latencyMs: found.latencyMs
                        )
                        self.emit(.hostFound(discovered), runID: runID)
                    }
                }

                startIndex = endIndex
            }

            emit(.sourceStatus(.probeFinished), runID: runID)
        }
    }

    nonisolated private static func probeSSHHost(
        _ host: String,
        timeout: TimeInterval
    ) async -> (host: String, latencyMs: Int)? {
        let startedAt = Date()
        let isReachable = await checkReachability(host: host, port: 22, timeout: timeout)
        guard isReachable else { return nil }

        let latencyMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
        return (host, latencyMs)
    }

    nonisolated private static func checkReachability(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "com.vivy.vvterm.discovery.probe.\(host)")
            let completionState = ReachabilityCompletionState()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard completionState.completeOnce() else { return }
                    continuation.resume(returning: true)
                    connection.cancel()
                case .failed, .cancelled:
                    guard completionState.completeOnce() else { return }
                    continuation.resume(returning: false)
                    connection.cancel()
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                guard completionState.completeOnce() else { return }
                continuation.resume(returning: false)
                connection.cancel()
            }

            connection.start(queue: queue)
        }
    }

    nonisolated private static func localSubnetCandidates() -> [String] {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else {
            return []
        }
        defer { freeifaddrs(interfacePointer) }

        var selectedAddress: UInt32?
        var selectedMask: UInt32?

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee

            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else {
                pointer = entry.ifa_next
                continue
            }

            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                pointer = entry.ifa_next
                continue
            }

            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

            let hostOrderAddress = UInt32(bigEndian: ipv4.sin_addr.s_addr)
            let hostOrderMask = UInt32(bigEndian: mask.sin_addr.s_addr)
            guard hostOrderAddress != 0, hostOrderMask != 0 else {
                pointer = entry.ifa_next
                continue
            }

            selectedAddress = hostOrderAddress
            selectedMask = hostOrderMask

            if let name = String(validatingUTF8: entry.ifa_name), name.hasPrefix("en") {
                break
            }

            pointer = entry.ifa_next
        }

        guard let address = selectedAddress, let mask = selectedMask else {
            return []
        }

        return enumerateHosts(address: address, netmask: mask)
    }

    nonisolated static func enumerateHosts(address: UInt32, netmask: UInt32) -> [String] {
        let prefixLength = netmask.nonzeroBitCount

        if prefixLength < 24 {
            let sliceMask: UInt32 = 0xFFFFFF00
            let sliceNetwork = address & sliceMask
            return hosts(in: sliceNetwork, broadcast: sliceNetwork | 0x000000FF, excluding: address)
        }

        let network = address & netmask
        let broadcast = network | ~netmask
        return hosts(in: network, broadcast: broadcast, excluding: address)
    }

    nonisolated static func hosts(
        in network: UInt32,
        broadcast: UInt32,
        excluding currentAddress: UInt32
    ) -> [String] {
        guard network < broadcast else { return [] }

        let (start, startOverflow) = network.addingReportingOverflow(1)
        let (end, endOverflow) = broadcast.subtractingReportingOverflow(1)
        guard !startOverflow, !endOverflow, start <= end else { return [] }

        let (distance, distanceOverflow) = end.subtractingReportingOverflow(start)
        let (candidateCount, countOverflow) = distance.addingReportingOverflow(1)
        let maximumCandidateCount: UInt32 = 254
        guard !distanceOverflow,
              !countOverflow,
              candidateCount <= maximumCandidateCount,
              let capacity = Int(exactly: candidateCount) else {
            return []
        }

        var result: [String] = []
        result.reserveCapacity(capacity)

        var address = start
        while true {
            if address != currentAddress {
                result.append(ipv4String(fromHostOrderAddress: address))
            }
            guard address != end else { break }
            let (nextAddress, overflow) = address.addingReportingOverflow(1)
            guard !overflow else { return [] }
            address = nextAddress
        }
        return result
    }

    nonisolated private static func ipv4String(fromHostOrderAddress address: UInt32) -> String {
        var networkOrderAddress = in_addr(s_addr: address.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let pointer = inet_ntop(
            AF_INET,
            &networkOrderAddress,
            &buffer,
            socklen_t(INET_ADDRSTRLEN)
        )
        return pointer == nil ? "" : String(cString: buffer)
    }

    nonisolated private static func sanitizedLocalHostName(from serviceName: String) -> String {
        let normalized = serviceName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .lowercased()
        return normalized.isEmpty ? serviceName : normalized
    }
}

// MARK: - NetServiceBrowserDelegate

extension LocalSSHDiscoveryService: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard let runID = browserRunIDs[ObjectIdentifier(browser)],
              runOwnership.owns(runID: runID) else {
            return
        }
        let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        // Policy denied values seen from local-network restricted states.
        if errorCode == -65570 || errorCode == -72008 {
            emit(.permissionDenied, runID: runID)
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard let runID = browserRunIDs[ObjectIdentifier(browser)],
              runOwnership.owns(runID: runID) else {
            return
        }
        let key = "\(service.name)|\(service.type)|\(service.domain)"
        guard seenServices.insert(key).inserted else { return }

        service.delegate = self
        servicesByName[key] = service
        serviceRunIDs[ObjectIdentifier(service)] = runID
        service.resolve(withTimeout: serviceResolveTimeout)
    }
}

// MARK: - NetServiceDelegate

extension LocalSSHDiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let runID = serviceRunIDs[ObjectIdentifier(sender)],
              runOwnership.owns(runID: runID) else {
            sender.delegate = nil
            sender.stop()
            return
        }
        let hostName = sender.hostName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedHost: String
        if let hostName, !hostName.isEmpty {
            resolvedHost = hostName
        } else {
            let fallback = Self.sanitizedLocalHostName(from: sender.name)
            resolvedHost = "\(fallback).local"
        }

        let port = sender.port > 0 ? sender.port : 22
        let discovered = DiscoveredSSHHost(
            displayName: sender.name.isEmpty ? resolvedHost : sender.name,
            host: resolvedHost,
            port: port,
            sources: [.bonjour]
        )
        emit(.hostFound(discovered), runID: runID)

        let key = "\(sender.name)|\(sender.type)|\(sender.domain)"
        servicesByName[key] = nil
        serviceRunIDs[ObjectIdentifier(sender)] = nil
        sender.delegate = nil
        sender.stop()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard let runID = serviceRunIDs[ObjectIdentifier(sender)],
              runOwnership.owns(runID: runID) else {
            sender.delegate = nil
            sender.stop()
            return
        }
        let fallback = Self.sanitizedLocalHostName(from: sender.name)
        let fallbackHost = "\(fallback).local"
        let port = sender.port > 0 ? sender.port : 22
        let discovered = DiscoveredSSHHost(
            displayName: sender.name.isEmpty ? fallbackHost : sender.name,
            host: fallbackHost,
            port: port,
            sources: [.bonjour]
        )
        emit(.hostFound(discovered), runID: runID)

        let key = "\(sender.name)|\(sender.type)|\(sender.domain)"
        servicesByName[key] = nil
        serviceRunIDs[ObjectIdentifier(sender)] = nil
        sender.delegate = nil
        sender.stop()
    }
}
