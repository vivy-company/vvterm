import Foundation
import Network
import Darwin

enum LocalSSHDiscoverySourceStatus: Sendable {
    case bonjourStarted
    case bonjourFinished
    case probeStarted
    case probeFinished
}

enum LocalSSHDiscoveryEvent: Sendable {
    case scanningStarted
    case sourceStatus(LocalSSHDiscoverySourceStatus)
    case hostFound(DiscoveredSSHHost)
    case permissionDenied
    case failed(String)
    case scanningFinished
}

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

    func startScan() -> AsyncStream<LocalSSHDiscoveryEvent> {
        stopScan()

        return AsyncStream { continuation in
            streamContinuation = continuation

            continuation.yield(.scanningStarted)
            startBonjourBrowsing()
            startPortScanning()
            startTimeoutTimer()
        }
    }

    func stopScan() {
        timeoutTask?.cancel()
        timeoutTask = nil

        probeTask?.cancel()
        probeTask = nil

        for browser in browsers {
            browser.delegate = nil
            browser.stop()
        }
        browsers.removeAll()

        for service in servicesByName.values {
            service.delegate = nil
            service.stop()
        }
        servicesByName.removeAll()
        seenServices.removeAll()

        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func startTimeoutTimer() {
        let duration = scanDuration
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.finishScan()
        }
    }

    private func finishScan() {
        streamContinuation?.yield(.sourceStatus(.bonjourFinished))
        streamContinuation?.yield(.sourceStatus(.probeFinished))
        streamContinuation?.yield(.scanningFinished)
        stopScan()
    }

    private func emit(_ event: LocalSSHDiscoveryEvent) {
        streamContinuation?.yield(event)
    }

    private func startBonjourBrowsing() {
        emit(.sourceStatus(.bonjourStarted))
        for serviceType in bonjourTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
        }
    }

    private func startPortScanning() {
        emit(.sourceStatus(.probeStarted))

        let timeout = portScanTimeout
        let concurrency = max(1, portScanConcurrency)

        probeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let candidates = Self.localSubnetCandidates()

            guard !candidates.isEmpty else {
                emit(.sourceStatus(.probeFinished))
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
                            await Self.probeSSHHost(host, timeout: timeout)
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
                        self.emit(.hostFound(discovered))
                    }
                }

                startIndex = endIndex
            }

            emit(.sourceStatus(.probeFinished))
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
            var completed = false

            let complete: (Bool) -> Void = { ready in
                guard !completed else { return }
                completed = true
                continuation.resume(returning: ready)
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(true)
                case .failed, .cancelled:
                    complete(false)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                complete(false)
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

    nonisolated private static func enumerateHosts(address: UInt32, netmask: UInt32) -> [String] {
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

    nonisolated private static func hosts(
        in network: UInt32,
        broadcast: UInt32,
        excluding currentAddress: UInt32
    ) -> [String] {
        guard broadcast > network + 1 else { return [] }

        let start = network + 1
        let end = broadcast - 1
        guard end >= start else { return [] }

        var result: [String] = []
        result.reserveCapacity(Int(end - start + 1))

        for ip in start...end where ip != currentAddress {
            result.append(ipv4String(fromHostOrderAddress: ip))
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
        let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        // Policy denied values seen from local-network restricted states.
        if errorCode == -65570 || errorCode == -72008 {
            emit(.permissionDenied)
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name)|\(service.type)|\(service.domain)"
        guard seenServices.insert(key).inserted else { return }

        service.delegate = self
        servicesByName[key] = service
        service.resolve(withTimeout: serviceResolveTimeout)
    }
}

// MARK: - NetServiceDelegate

extension LocalSSHDiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
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
        emit(.hostFound(discovered))

        let key = "\(sender.name)|\(sender.type)|\(sender.domain)"
        servicesByName[key] = nil
        sender.stop()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let fallback = Self.sanitizedLocalHostName(from: sender.name)
        let fallbackHost = "\(fallback).local"
        let port = sender.port > 0 ? sender.port : 22
        let discovered = DiscoveredSSHHost(
            displayName: sender.name.isEmpty ? fallbackHost : sender.name,
            host: fallbackHost,
            port: port,
            sources: [.bonjour]
        )
        emit(.hostFound(discovered))

        let key = "\(sender.name)|\(sender.type)|\(sender.domain)"
        servicesByName[key] = nil
        sender.stop()
    }
}
