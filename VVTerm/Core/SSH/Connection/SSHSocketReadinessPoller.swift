import Darwin
import Foundation

/// Coalesces short libssh2 socket waits onto one dedicated serial queue.
/// SSHSession actors suspend while the queue performs the blocking poll call.
nonisolated final class SSHSocketReadinessPoller: @unchecked Sendable {
    static let shared = SSHSocketReadinessPoller()

    private struct Request {
        let id: UUID
        let fileDescriptor: Int32
        let events: Int16
        let deadlineNanoseconds: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let queue: DispatchQueue
    private var requests: [UUID: Request] = [:]
    private var isPolling = false

    init(label: String = "app.vivy.VVTerm.ssh-socket-readiness") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func wait(
        fileDescriptor: Int32,
        events: Int16,
        timeoutMilliseconds: Int32
    ) async {
        guard fileDescriptor >= 0, events != 0, timeoutMilliseconds > 0 else { return }
        guard !Task.isCancelled else { return }

        let requestID = UUID()
        let cancellation = WaitCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    guard !cancellation.isCancelled else {
                        continuation.resume()
                        return
                    }

                    let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
                    let now = DispatchTime.now().uptimeNanoseconds
                    let deadline = now.addingReportingOverflow(timeoutNanoseconds)
                    let request = Request(
                        id: requestID,
                        fileDescriptor: fileDescriptor,
                        events: events,
                        deadlineNanoseconds: deadline.overflow ? UInt64.max : deadline.partialValue,
                        continuation: continuation
                    )
                    requests[requestID] = request
                    startPollingIfNeeded()
                }
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            self?.queue.async { [weak self] in
                self?.finish(requestID)
            }
        }
    }

    private func startPollingIfNeeded() {
        guard !isPolling, !requests.isEmpty else { return }
        isPolling = true
        queue.async { [weak self] in
            self?.pollOnce()
        }
    }

    private func pollOnce() {
        guard !requests.isEmpty else {
            isPolling = false
            return
        }

        let snapshot = Array(requests.values)
        var descriptors = snapshot.map {
            pollfd(fd: $0.fileDescriptor, events: $0.events, revents: 0)
        }
        let timeout = pollTimeoutMilliseconds(for: snapshot)
        let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), timeout)
        let now = DispatchTime.now().uptimeNanoseconds

        if result < 0, errno == EINTR {
            queue.async { [weak self] in
                self?.pollOnce()
            }
            return
        }

        for index in snapshot.indices {
            let request = snapshot[index]
            let isReady = descriptors[index].revents != 0
            if isReady || now >= request.deadlineNanoseconds || result < 0 {
                finish(request.id)
            }
        }

        if requests.isEmpty {
            isPolling = false
        } else {
            queue.async { [weak self] in
                self?.pollOnce()
            }
        }
    }

    private func pollTimeoutMilliseconds(for requests: [Request]) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let earliestDeadline = requests.map(\.deadlineNanoseconds).min() else { return 0 }
        guard earliestDeadline > now else { return 0 }

        let remainingNanoseconds = earliestDeadline - now
        let wholeMilliseconds = remainingNanoseconds / 1_000_000
        let roundedMilliseconds = wholeMilliseconds + (remainingNanoseconds.isMultiple(of: 1_000_000) ? 0 : 1)
        // Keep the queue responsive to newly registered and cancelled waits.
        return Int32(min(roundedMilliseconds, 5))
    }

    private func finish(_ requestID: UUID) {
        requests.removeValue(forKey: requestID)?.continuation.resume()
    }
}

private nonisolated final class WaitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}
