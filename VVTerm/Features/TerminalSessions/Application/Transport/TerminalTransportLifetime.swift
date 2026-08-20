import Foundation

/// Owns transport identities, queued I/O, and cleanup for one terminal manager.
@MainActor
final class TerminalTransportLifetime {
    struct SSHResizeState {
        let clientIdentity: ObjectIdentifier
        let shellId: UUID
        let cols: Int
        let rows: Int
        let pixelSize: TerminalPixelSize?
    }

    let registry: TerminalTransportRegistry<EternalTerminalRuntime>

    private var writeQueuesByPane: [UUID: TerminalTransportWriteQueue] = [:]
    private var lastSSHResizeByPane: [UUID: SSHResizeState] = [:]

    init(staleShellStartThreshold: TimeInterval = 120) {
        registry = TerminalTransportRegistry(
            staleShellStartThreshold: staleShellStartThreshold
        )
    }

    isolated deinit {
        let drainedTransports = drain()
        for client in drainedTransports.clients {
            Task { await client.disconnect() }
        }
        for runtime in drainedTransports.runtimes {
            Task { @MainActor in await runtime.close() }
        }
    }

    func writeQueue(for paneId: UUID) -> TerminalTransportWriteQueue {
        if let queue = writeQueuesByPane[paneId] {
            return queue
        }
        let queue = TerminalTransportWriteQueue()
        writeQueuesByPane[paneId] = queue
        return queue
    }

    func shouldScheduleResize(
        for paneId: UUID,
        client: SSHClient,
        shellId: UUID,
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?
    ) -> Bool {
        let state = SSHResizeState(
            clientIdentity: ObjectIdentifier(client),
            shellId: shellId,
            cols: cols,
            rows: rows,
            pixelSize: pixelSize
        )
        if let previous = lastSSHResizeByPane[paneId],
           previous.clientIdentity == state.clientIdentity,
           previous.shellId == state.shellId,
           previous.cols == state.cols,
           previous.rows == state.rows,
           previous.pixelSize == state.pixelSize {
            return false
        }
        lastSSHResizeByPane[paneId] = state
        return true
    }

    func cancelQueuedIO(for paneId: UUID) {
        writeQueuesByPane.removeValue(forKey: paneId)?.cancel()
        lastSSHResizeByPane.removeValue(forKey: paneId)
    }

    func unregisterShell(
        for paneId: UUID,
        ifOwnedBy registration: TerminalTmuxShellRegistration
    ) async {
        guard registry.ownsShell(
            client: registration.client,
            shellId: registration.shellId,
            for: paneId
        ) else { return }

        registry.cancelConnectionTask(for: paneId)
        cancelQueuedIO(for: paneId)
        let ownership = registry.unregisterShell(for: paneId)
        guard let removed = ownership.registration else { return }

        await registry.performTrackedCleanup(for: removed.client) {
            if !self.registry.hasClientReferences(removed.client) {
                await removed.client.disconnect()
            } else {
                await removed.client.closeShell(removed.shellId)
            }
        }
    }

    @discardableResult
    func unregisterRuntime(
        for paneId: UUID,
        ifOwnedBy runtime: EternalTerminalRuntime
    ) async -> Bool {
        guard registry.detachRuntime(runtime, for: paneId) else { return false }
        await runtime.close()
        return true
    }

    func drain() -> TerminalTransportRegistry<EternalTerminalRuntime>.DrainResult {
        let drainedTransports = registry.drain()
        let queues = Array(writeQueuesByPane.values)
        writeQueuesByPane.removeAll()
        lastSSHResizeByPane.removeAll()
        for queue in queues {
            queue.cancel()
        }
        return drainedTransports
    }
}
