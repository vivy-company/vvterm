import Darwin
import Foundation
import os

nonisolated enum SSHAddressFamily: String, Equatable, Sendable {
    case ipv4
    case ipv6
    case other

    init(rawValue: Int32) {
        switch rawValue {
        case AF_INET:
            self = .ipv4
        case AF_INET6:
            self = .ipv6
        default:
            self = .other
        }
    }
}

nonisolated enum SSHAddressCandidatePolicy {
    static let fallbackDelay: Duration = .milliseconds(250)
    static let maximumCandidateCount = 8

    static func interleavedFamilies(_ families: [SSHAddressFamily]) -> [SSHAddressFamily] {
        interleaved(families) { $0 }
    }

    static func launchOffsets(candidateCount: Int) -> [Duration] {
        guard candidateCount > 0 else { return [] }
        let boundedCount = min(candidateCount, maximumCandidateCount)
        return (0..<boundedCount).map { fallbackDelay * $0 }
    }

    static func interleaved<Value>(
        _ values: [Value],
        family: (Value) -> SSHAddressFamily
    ) -> [Value] {
        guard let first = values.first else { return [] }
        let preferredFamily = family(first)
        let alternateFamily: SSHAddressFamily? = preferredFamily == .ipv6
            ? (values.contains { family($0) == .ipv4 } ? .ipv4 : nil)
            : (preferredFamily == .ipv4 && values.contains { family($0) == .ipv6 } ? .ipv6 : nil)
        guard let alternateFamily else { return values }

        let preferred = values.filter { family($0) == preferredFamily }
        let fallback = values.filter { family($0) == alternateFamily }
        let remaining = values.filter {
            family($0) != preferredFamily && family($0) != alternateFamily
        }
        var result: [Value] = []
        result.reserveCapacity(values.count)
        for index in 0..<max(preferred.count, fallback.count) {
            if index < preferred.count { result.append(preferred[index]) }
            if index < fallback.count { result.append(fallback[index]) }
        }
        return result + remaining
    }
}

nonisolated enum SSHAddressConnector {
    struct Candidate: Sendable {
        let family: SSHAddressFamily
        let socketFamily: Int32
        let socketType: Int32
        let protocolNumber: Int32
        let address: Data
        let addressLength: socklen_t
    }

    private struct PendingSocket {
        let descriptor: Int32
        let family: SSHAddressFamily
        let originalFlags: Int32
        let attemptToken: SSHStartupTrace.Token?
    }

    private final class ResolutionState: Sendable {
        private enum Status {
            case waiting
            case suspended(CheckedContinuation<[Candidate], Error>)
            case finished
        }

        private let status = OSAllocatedUnfairLock(initialState: Status.waiting)

        func install(_ continuation: CheckedContinuation<[Candidate], Error>) -> Bool {
            let wasCancelled = status.withLock { state -> Bool in
                guard case .waiting = state else { return true }
                state = .suspended(continuation)
                return false
            }
            if wasCancelled {
                continuation.resume(throwing: CancellationError())
            }
            return !wasCancelled
        }

        func complete(_ result: Result<[Candidate], Error>) {
            let continuation = status.withLock { state -> CheckedContinuation<[Candidate], Error>? in
                guard case .suspended(let continuation) = state else { return nil }
                state = .finished
                return continuation
            }
            continuation?.resume(with: result)
        }

        func cancel() {
            let continuation = status.withLock { state -> CheckedContinuation<[Candidate], Error>? in
                switch state {
                case .waiting:
                    state = .finished
                    return nil
                case .suspended(let continuation):
                    state = .finished
                    return continuation
                case .finished:
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    static func connect(
        host: String,
        port: Int,
        trace: SSHStartupTrace?
    ) async throws -> Int32 {
        let dnsToken = trace?.begin(.dnsResolution)
        let candidates: [Candidate]
        do {
            candidates = try await resolveCancellable(host: host, port: port)
            if let dnsToken { trace?.end(dnsToken, detail: "candidates_\(min(candidates.count, 9))") }
        } catch {
            if let dnsToken { trace?.end(dnsToken, outcome: "failed") }
            throw error
        }

        return try await connect(candidates: candidates, trace: trace)
    }

    static func connect(
        candidates: [Candidate],
        trace: SSHStartupTrace?,
        timeout: Duration = .seconds(8)
    ) async throws -> Int32 {
        let ordered = interleaved(candidates).prefix(SSHAddressCandidatePolicy.maximumCandidateCount)
        guard !ordered.isEmpty else {
            throw SSHError.connectionFailed("No usable addresses")
        }

        let candidateList = Array(ordered)
        let offsets = SSHAddressCandidatePolicy.launchOffsets(candidateCount: candidateList.count)
        let startedAt = ContinuousClock.now
        let deadline = startedAt.advanced(by: timeout)
        var pending: [PendingSocket] = []
        var nextCandidate = 0
        var lastError: Int32 = 0
        var unfinishedAttemptOutcome = "abandoned"

        defer {
            for item in pending {
                Darwin.close(item.descriptor)
                if let attemptToken = item.attemptToken {
                    trace?.end(
                        attemptToken,
                        outcome: unfinishedAttemptOutcome,
                        detail: item.family.rawValue
                    )
                }
            }
        }

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let elapsed = startedAt.duration(to: .now)

            while nextCandidate < candidateList.count {
                if elapsed < offsets[nextCandidate], !pending.isEmpty {
                    break
                }
                let candidate = candidateList[nextCandidate]
                nextCandidate += 1
                let attemptToken = trace?.begin(.tcpAddressAttempt)

                let descriptor = Darwin.socket(
                    candidate.socketFamily,
                    candidate.socketType,
                    candidate.protocolNumber
                )
                guard descriptor >= 0 else {
                    lastError = errno
                    if let attemptToken {
                        trace?.end(attemptToken, outcome: "failed", detail: candidate.family.rawValue)
                    }
                    continue
                }

                let originalFlags = fcntl(descriptor, F_GETFL, 0)
                _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
                let result = candidate.address.withUnsafeBytes { bytes -> Int32 in
                    guard let baseAddress = bytes.baseAddress else { return -1 }
                    return Darwin.connect(
                        descriptor,
                        baseAddress.assumingMemoryBound(to: sockaddr.self),
                        candidate.addressLength
                    )
                }

                if result == 0 {
                    _ = fcntl(descriptor, F_SETFL, originalFlags)
                    if let attemptToken { trace?.end(attemptToken, detail: candidate.family.rawValue) }
                    unfinishedAttemptOutcome = "superseded"
                    return descriptor
                }

                if errno == EINPROGRESS {
                    pending.append(
                        PendingSocket(
                            descriptor: descriptor,
                            family: candidate.family,
                            originalFlags: originalFlags,
                            attemptToken: attemptToken
                        )
                    )
                } else {
                    lastError = errno
                    Darwin.close(descriptor)
                    if let attemptToken {
                        trace?.end(attemptToken, outcome: "failed", detail: candidate.family.rawValue)
                    }
                }
            }

            if pending.isEmpty, nextCandidate >= candidateList.count {
                break
            }

            var pollDescriptors = pending.map {
                pollfd(fd: $0.descriptor, events: Int16(POLLOUT), revents: 0)
            }
            let pollResult = Darwin.poll(&pollDescriptors, nfds_t(pollDescriptors.count), 50)
            if pollResult < 0, errno != EINTR {
                lastError = errno
                break
            }

            for index in pollDescriptors.indices.reversed() where pollDescriptors[index].revents != 0 {
                let item = pending[index]
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(item.descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length)
                if socketError == 0 {
                    pending.remove(at: index)
                    _ = fcntl(item.descriptor, F_SETFL, item.originalFlags)
                    if let attemptToken = item.attemptToken {
                        trace?.end(attemptToken, detail: item.family.rawValue)
                    }
                    unfinishedAttemptOutcome = "superseded"
                    return item.descriptor
                }
                lastError = socketError
                Darwin.close(item.descriptor)
                pending.remove(at: index)
                if let attemptToken = item.attemptToken {
                    trace?.end(attemptToken, outcome: "failed", detail: item.family.rawValue)
                }
            }
        }

        unfinishedAttemptOutcome = "failed"
        let message = lastError == 0 ? "Connection timed out" : String(cString: strerror(lastError))
        throw SSHError.connectionFailed("Failed to connect: \(message)")
    }

    static func resolvedCandidates(host: String, port: Int) throws -> [Candidate] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = resolutionFlags(for: host)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw SSHError.connectionFailed("Failed to resolve host")
        }
        defer { freeaddrinfo(result) }

        var candidates: [Candidate] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let item = current {
            let info = item.pointee
            if let address = info.ai_addr, info.ai_addrlen > 0 {
                candidates.append(
                    Candidate(
                        family: SSHAddressFamily(rawValue: info.ai_family),
                        socketFamily: info.ai_family,
                        socketType: info.ai_socktype == 0 ? SOCK_STREAM : info.ai_socktype,
                        protocolNumber: info.ai_protocol,
                        address: Data(bytes: address, count: Int(info.ai_addrlen)),
                        addressLength: info.ai_addrlen
                    )
                )
            }
            current = info.ai_next
        }
        return candidates
    }

    static func resolutionFlags(for host: String) -> Int32 {
        var ipv4Address = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            return AI_NUMERICHOST | AI_NUMERICSERV
        }

        var ipv6Address = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6Address) }) == 1 {
            return AI_NUMERICHOST | AI_NUMERICSERV
        }

        return AI_NUMERICSERV
    }

    private static func resolveCancellable(host: String, port: Int) async throws -> [Candidate] {
        let state = ResolutionState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    state.complete(Result {
                        try resolvedCandidates(host: host, port: port)
                    })
                }
            }
        }, onCancel: {
            state.cancel()
        })
    }

    private static func interleaved(_ candidates: [Candidate]) -> [Candidate] {
        SSHAddressCandidatePolicy.interleaved(candidates) { $0.family }
    }
}
