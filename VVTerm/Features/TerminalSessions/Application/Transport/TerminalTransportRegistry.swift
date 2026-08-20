import Foundation

/// Owns the live transport identities and tasks for terminal panes.
@MainActor
final class TerminalTransportRegistry<Runtime: AnyObject> {
    struct ShellRoute {
        let client: SSHClient
        let shellId: UUID
    }

    struct DrainResult {
        let clients: [SSHClient]
        let runtimes: [Runtime]
    }

    private struct ConnectionCleanup {
        let client: SSHClient
        let task: Task<Void, Never>
    }

    private var shells: SSHShellRegistry
    private let connectionTasks = TerminalConnectionTaskStore()
    private var runtimesByPane: [UUID: Runtime] = [:]
    private var cleanupsInFlight: [UUID: ConnectionCleanup] = [:]

    init(staleShellStartThreshold: TimeInterval) {
        shells = SSHShellRegistry(staleThreshold: staleShellStartThreshold)
    }

    #if compiler(<6.4)
    // Xcode 26.5 crashes while optimizing the isolated destructor of a generic
    // MainActor class. Xcode 27 fixes the compiler bug.
    @_optimize(none)
    deinit {}
    #endif

    var ownedPaneIds: Set<UUID> {
        Set(shells.registrations.keys)
            .union(shells.startsInFlight.keys)
            .union(runtimesByPane.keys)
            .union(connectionTasks.paneIds)
    }

    func hasLiveTransport(for paneId: UUID) -> Bool {
        shells.shellId(for: paneId) != nil || runtimesByPane[paneId] != nil
    }

    func shellRoute(for paneId: UUID) -> ShellRoute? {
        guard let client = shells.client(for: paneId),
              let shellId = shells.shellId(for: paneId) else { return nil }
        return ShellRoute(client: client, shellId: shellId)
    }

    func shellRegistration(for paneId: UUID) -> SSHShellRegistry.Registration? {
        shells.registration(for: paneId)
    }

    func shellId(for paneId: UUID) -> UUID? {
        shells.shellId(for: paneId)
    }

    func registeredClient(for paneId: UUID) -> SSHClient? {
        shells.client(for: paneId)
    }

    func connectionClient(for paneId: UUID) -> SSHClient? {
        shells.connectionClient(for: paneId)
    }

    func connectionStartToken(for paneId: UUID) -> SSHShellRegistry.StartToken? {
        shells.connectionStartToken(for: paneId)
    }

    func beginShellStart(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        now: Date = Date()
    ) -> SSHShellRegistry.StartResult {
        shells.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client,
            now: now
        )
    }

    func finishShellStart(
        for paneId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) {
        shells.finishStart(
            for: paneId,
            client: client,
            startToken: startToken
        )
    }

    func shellStartStatus(
        for paneId: UUID,
        now: Date = Date()
    ) -> SSHShellRegistry.InFlightResult {
        shells.isStartInFlight(for: paneId, now: now)
    }

    func registerShell(
        client: SSHClient,
        shellId: UUID,
        startToken: SSHShellRegistry.StartToken,
        for paneId: UUID,
        serverId: UUID
    ) -> SSHShellRegistry.RegisterResult {
        shells.register(
            client: client,
            shellId: shellId,
            startToken: startToken,
            for: paneId,
            serverId: serverId
        )
    }

    func unregisterShell(
        for paneId: UUID
    ) -> (registration: SSHShellRegistry.Registration?, pendingStart: SSHShellRegistry.StartContext?) {
        shells.unregister(for: paneId)
    }

    func ownsShell(client: SSHClient, shellId: UUID, for paneId: UUID) -> Bool {
        shells.owns(client: client, shellId: shellId, for: paneId)
    }

    func ownsConnection(
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken,
        for paneId: UUID
    ) -> Bool {
        shells.ownsConnection(
            client: client,
            startToken: startToken,
            for: paneId
        )
    }

    func ownsConnection(startToken: SSHShellRegistry.StartToken, for paneId: UUID) -> Bool {
        shells.owns(startToken: startToken, for: paneId)
    }

    func hasClientReferences(_ client: SSHClient) -> Bool {
        shells.hasClientReferences(client)
    }

    func hasOtherClientReferences(using client: SSHClient, excluding paneId: UUID) -> Bool {
        shells.hasOtherClientReferences(using: client, excluding: paneId)
    }

    func firstRegisteredClient(for serverId: UUID) -> SSHClient? {
        shells.firstRegisteredClient(for: serverId)
    }

    func firstPendingClient(for serverId: UUID) -> SSHClient? {
        shells.firstPendingClient(for: serverId)
    }

    @discardableResult
    func startConnectionTask(
        for paneId: UUID,
        operation: @escaping @Sendable (_ taskId: UUID) async -> Void
    ) -> UUID? {
        connectionTasks.start(for: paneId, operation: operation)
    }

    func isCurrentConnectionTask(taskId: UUID, for paneId: UUID) -> Bool {
        connectionTasks.isCurrent(taskId: taskId, for: paneId)
    }

    @discardableResult
    func cancelConnectionTask(for paneId: UUID) -> Bool {
        connectionTasks.cancel(for: paneId)
    }

    func runtime(for paneId: UUID) -> Runtime? {
        runtimesByPane[paneId]
    }

    func runtime(
        for paneId: UUID,
        create: () -> Runtime
    ) -> Runtime {
        if let runtime = runtimesByPane[paneId] {
            return runtime
        }
        let runtime = create()
        runtimesByPane[paneId] = runtime
        return runtime
    }

    func isCurrentRuntime(_ runtime: Runtime, for paneId: UUID) -> Bool {
        runtimesByPane[paneId] === runtime
    }

    @discardableResult
    func detachRuntime(_ runtime: Runtime, for paneId: UUID) -> Bool {
        guard isCurrentRuntime(runtime, for: paneId) else { return false }
        runtimesByPane.removeValue(forKey: paneId)
        return true
    }

    func forEachRuntime(
        _ operation: @MainActor (Runtime) async -> Void
    ) async {
        let runtimes = Array(runtimesByPane.values)
        for runtime in runtimes {
            await operation(runtime)
        }
    }

    func performTrackedCleanup(
        for client: SSHClient,
        operation: @MainActor @Sendable @escaping () async -> Void
    ) async {
        let cleanupId = UUID()
        let task = Task { @MainActor in
            await operation()
        }
        cleanupsInFlight[cleanupId] = ConnectionCleanup(client: client, task: task)
        await task.value
        cleanupsInFlight.removeValue(forKey: cleanupId)
    }

    func drain() -> DrainResult {
        connectionTasks.cancelAll()
        let shellOwnership = shells.drain()
        let cleanups = Array(cleanupsInFlight.values)
        cleanupsInFlight.removeAll()
        for cleanup in cleanups {
            cleanup.task.cancel()
        }
        var uniqueRuntimes: [ObjectIdentifier: Runtime] = [:]
        for runtime in runtimesByPane.values {
            uniqueRuntimes[ObjectIdentifier(runtime)] = runtime
        }
        runtimesByPane.removeAll()

        var uniqueClients: [ObjectIdentifier: SSHClient] = [:]
        for registration in shellOwnership.registrations {
            uniqueClients[ObjectIdentifier(registration.client)] = registration.client
        }
        for start in shellOwnership.pendingStarts {
            uniqueClients[ObjectIdentifier(start.client)] = start.client
        }
        for cleanup in cleanups {
            uniqueClients[ObjectIdentifier(cleanup.client)] = cleanup.client
        }
        return DrainResult(
            clients: Array(uniqueClients.values),
            runtimes: Array(uniqueRuntimes.values)
        )
    }
}
