import Foundation

/// libssh2 has process-global lifecycle (`libssh2_init`/`libssh2_exit`).
/// Initialize once and keep alive for the app lifetime to avoid tearing down
/// the library while other SSH sessions are still active.
nonisolated enum LibSSH2Runtime {
    private static let lock = NSLock()
    /// Access is serialized by `lock`; libssh2 initialization is process-global.
    nonisolated(unsafe) private static var initialized = false

    static func ensureInitialized() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }
        let rc = libssh2_init(0)
        guard rc == 0 else {
            throw SSHError.unknown("libssh2_init failed: \(rc)")
        }
        initialized = true
    }

    nonisolated static func supports(requiredVersion: Int32) -> Bool {
        libssh2_version(requiredVersion) != nil
    }
}
