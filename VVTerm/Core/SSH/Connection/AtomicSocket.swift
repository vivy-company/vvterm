import Darwin
import Foundation

/// Thread-safe socket storage that separates cross-thread I/O interruption
/// from the actor-owned final descriptor close.
final class AtomicSocket: @unchecked Sendable {
    private enum State: Sendable {
        case closed
        case open(Int32)
        case interrupted(Int32)
    }

    private nonisolated(unsafe) var state = State.closed
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated var isUsable: Bool {
        lock.withLock {
            if case .open = state {
                true
            } else {
                false
            }
        }
    }

    nonisolated func install(_ socket: Int32) {
        lock.withLock {
            state = .open(socket)
        }
    }

    /// Wake blocking socket I/O without releasing the descriptor. This avoids
    /// descriptor reuse while libssh2 may still be returning from a native call.
    nonisolated func interrupt() {
        lock.withLock {
            guard case .open(let socket) = state else { return }
            Darwin.shutdown(socket, SHUT_RDWR)
            state = .interrupted(socket)
        }
    }

    /// Release the descriptor after the SSHSession actor has finished libssh2 cleanup.
    nonisolated func close() {
        lock.withLock {
            switch state {
            case .closed:
                return
            case .open(let socket), .interrupted(let socket):
                Darwin.close(socket)
                state = .closed
            }
        }
    }
}
