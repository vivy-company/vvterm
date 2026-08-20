import Foundation
import os.log

nonisolated enum TerminalTransportEndOwnership: Sendable {
    case ssh(client: SSHClient, shellId: UUID)
    case eternalTerminal(runtimeToken: UUID)
}

@MainActor
struct TerminalTransportSessionAccess {
    let paneState: (UUID) -> TerminalPaneState?
    let allPaneStates: () -> [TerminalPaneState]
    let selectedTab: (UUID) -> TerminalTab?
    let tabs: (UUID) -> [TerminalTab]
    let containsPane: (UUID) -> Bool
    let workingDirectory: (UUID) -> String?
    let shouldApplyWorkingDirectory: (UUID) -> Bool
    let send: (TerminalTransportSessionEvent) -> Void
}

nonisolated enum TerminalTransportSessionEvent: Sendable {
    case activeTransport(UUID, ShellTransportState)
    case eternalTerminalResumeContext(UUID, EternalTerminalTmuxResumeContext?)
    case connectionState(UUID, ConnectionState)
    case title(UUID, String)
    case shellEnd(UUID, TerminalShellEndReason, TerminalTransportEndOwnership?)
}

/// Owns terminal transport identities, tasks, resumable state, and cleanup.
@MainActor
final class TerminalTransportCoordinator {
    private typealias SSHOwnership = (
        registration: SSHShellRegistry.Registration?,
        pendingStart: SSHShellRegistry.StartContext?
    )

    private let lifetime: TerminalTransportLifetime
    private var registry: TerminalTransportRegistry<EternalTerminalRuntime> {
        lifetime.registry
    }
    private let sshClientFactory: SSHClientFactory
    #if DEBUG
    private var eternalTerminalResumeStore: any EternalTerminalResumeStoring
    private let defaultEternalTerminalResumeStore: any EternalTerminalResumeStoring
    #else
    private let eternalTerminalResumeStore: any EternalTerminalResumeStoring
    #endif
    private let moshRecovery: any TerminalMoshRecoveryServicing
    private let remoteMosh: any TerminalRemoteMoshServicing
    private let eternalTerminalRuntimeDependencies: EternalTerminalRuntimeDependencies
    private let sessionAccess: TerminalTransportSessionAccess
    private let tmuxCoordinator: TerminalTmuxSessionCoordinator
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "TerminalTransportCoordinator"
    )

    init(
        lifetime: TerminalTransportLifetime,
        sshClientFactory: SSHClientFactory,
        eternalTerminalResumeStore: any EternalTerminalResumeStoring,
        moshRecovery: any TerminalMoshRecoveryServicing,
        remoteMosh: any TerminalRemoteMoshServicing,
        eternalTerminalRuntimeDependencies: EternalTerminalRuntimeDependencies,
        sessionAccess: TerminalTransportSessionAccess,
        tmuxCoordinator: TerminalTmuxSessionCoordinator
    ) {
        self.lifetime = lifetime
        self.sshClientFactory = sshClientFactory
        self.eternalTerminalResumeStore = eternalTerminalResumeStore
        #if DEBUG
        defaultEternalTerminalResumeStore = eternalTerminalResumeStore
        #endif
        self.moshRecovery = moshRecovery
        self.remoteMosh = remoteMosh
        self.eternalTerminalRuntimeDependencies = eternalTerminalRuntimeDependencies
        self.sessionAccess = sessionAccess
        self.tmuxCoordinator = tmuxCoordinator
    }

    var ownedPaneIds: Set<UUID> {
        registry.ownedPaneIds
    }

    func makeSSHClient() -> SSHClient {
        sshClientFactory.makeClient()
    }

    func hasLiveTransport(for paneId: UUID) -> Bool {
        registry.hasLiveTransport(for: paneId)
    }

    func activeSSHRoute(for paneId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let route = registry.shellRoute(for: paneId) else { return nil }
        return (route.client, route.shellId)
    }

    func handleShellEnd(
        for paneId: UUID,
        client: SSHClient,
        shellId: UUID,
        reason: TerminalShellEndReason
    ) {
        guard registry.ownsShell(client: client, shellId: shellId, for: paneId) else {
            logger.info("Ignoring stale shell end for pane \(paneId.uuidString, privacy: .public)")
            return
        }
        sessionAccess.send(.shellEnd(
            paneId,
            reason,
            .ssh(client: client, shellId: shellId)
        ))
    }

    func connectionOwnershipToken(for paneId: UUID) -> SSHShellRegistry.StartToken? {
        registry.connectionStartToken(for: paneId)
    }

    func sendSSHInput(_ data: Data, for paneId: UUID) {
        guard let route = registry.shellRoute(for: paneId) else { return }
        let queue = lifetime.writeQueue(for: paneId)
        let registry = registry
        let logger = logger
        queue.enqueue { [weak registry] in
            guard registry?.ownsShell(
                client: route.client,
                shellId: route.shellId,
                for: paneId
            ) == true else { return }
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func resizeSSH(
        for paneId: UUID,
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?
    ) {
        guard cols > 0, rows > 0,
              let route = registry.shellRoute(for: paneId) else { return }
        guard lifetime.shouldScheduleResize(
            for: paneId,
            client: route.client,
            shellId: route.shellId,
            cols: cols,
            rows: rows,
            pixelSize: pixelSize
        ) else { return }
        let registry = registry
        let logger = logger
        Task(priority: .userInitiated) { [weak registry] in
            guard registry?.ownsShell(
                client: route.client,
                shellId: route.shellId,
                for: paneId
            ) == true else { return }
            do {
                try await route.client.resize(
                    cols: cols,
                    rows: rows,
                    pixelSize: pixelSize,
                    for: route.shellId
                )
            } catch {
                logger.warning("Failed to resize PTY: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func hasEternalTerminalRuntime(for paneId: UUID) -> Bool {
        registry.runtime(for: paneId) != nil
    }

    func eternalTerminalRuntime(
        for paneId: UUID,
        server: Server,
        credentials: ServerCredentials
    ) -> EternalTerminalRuntime {
        if let runtime = registry.runtime(for: paneId) {
            return runtime
        }

        let runtime = EternalTerminalRuntime(
            paneId: paneId,
            server: server,
            credentials: credentials,
            ownerAccess: makeEternalTerminalOwnerAccess(),
            dependencies: eternalTerminalRuntimeDependencies
        )
        _ = registry.runtime(for: paneId) { runtime }
        markEternalTerminalTransport(for: paneId)
        return runtime
    }

    func sendEternalTerminalInput(_ data: Data, for paneId: UUID) {
        registry.runtime(for: paneId)?.send(data)
    }

    func resizeEternalTerminal(
        for paneId: UUID,
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?
    ) {
        guard let runtime = registry.runtime(for: paneId) else { return }
        runtime.resize(cols: cols, rows: rows, pixelSize: pixelSize)
        runtime.startIfNeeded()
    }

    func isCurrentEternalTerminalRuntime(
        _ runtime: EternalTerminalRuntime,
        for paneId: UUID
    ) -> Bool {
        registry.isCurrentRuntime(runtime, for: paneId)
    }

    func unregisterEternalTerminalRuntime(
        for paneId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String? = nil
    ) async {
        guard let runtime = registry.runtime(for: paneId),
              detachEternalTerminalRuntime(for: paneId, ifOwnedBy: runtime) else { return }
        if let tmuxSessionName {
            await tmuxCoordinator.killSession(named: tmuxSessionName, using: runtime)
        }
        await runtime.close()
    }

    func unregisterEternalTerminalRuntimeIfPaneWasRemoved(for paneId: UUID) {
        guard !sessionAccess.containsPane(paneId),
              let runtime = registry.runtime(for: paneId),
              registry.detachRuntime(runtime, for: paneId) else { return }
        Task { await runtime.close() }
    }

    func unregisterEternalTerminalRuntime(
        for paneId: UUID,
        ifOwnedBy runtime: EternalTerminalRuntime
    ) async {
        guard detachEternalTerminalRuntime(for: paneId, ifOwnedBy: runtime) else { return }
        await runtime.close()
    }

    func unregisterEternalTerminalRuntime(
        for paneId: UUID,
        ifOwnedByToken token: UUID
    ) async {
        guard let runtime = registry.runtime(for: paneId),
              runtime.identityToken == token else { return }
        await unregisterEternalTerminalRuntime(for: paneId, ifOwnedBy: runtime)
    }

    @discardableResult
    func detachEternalTerminalRuntime(
        for paneId: UUID,
        ifOwnedBy runtime: EternalTerminalRuntime
    ) -> Bool {
        guard registry.detachRuntime(runtime, for: paneId) else { return false }
        if sessionAccess.containsPane(paneId) {
            sessionAccess.send(.activeTransport(paneId, .ssh))
        }
        return true
    }

    func beginEternalTerminalNetworkRecoveryProbe(for paneId: UUID) async -> UUID? {
        await registry.runtime(for: paneId)?.beginNetworkRecoveryProbe()
    }

    func notifyEternalTerminalNetworkPathChanged(for paneId: UUID) {
        guard let runtime = registry.runtime(for: paneId) else { return }
        Task { await runtime.notifyNetworkPathChanged() }
    }

    func completedEternalTerminalNetworkRecoveryProbe(
        _ probeId: UUID,
        for paneId: UUID
    ) -> Bool {
        registry.runtime(for: paneId)?.completedNetworkRecoveryProbe(probeId) == true
    }

    #if os(macOS)
    func hasVerifiedLiveTransport(
        for paneId: UUID,
        eternalTerminalProbeID: UUID? = nil
    ) async -> Bool {
        guard let paneState = sessionAccess.paneState(paneId) else { return false }
        if paneState.activeTransport == .eternalTerminal {
            let runtime = registry.runtime(for: paneId)
            let completedProbe = eternalTerminalProbeID.map {
                runtime?.completedNetworkRecoveryProbe($0) == true
            } ?? false
            return MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: paneState.connectionState,
                activeTransport: paneState.activeTransport,
                hasEternalTerminalRuntime: runtime != nil,
                hasShellOwnership: false,
                transportIsLive: completedProbe
            )
        }

        let route = registry.shellRoute(for: paneId)
        let transportIsLive = if let route {
            await route.client.probeLiveTransport(
                shellId: route.shellId,
                transport: paneState.activeTransport
            )
        } else {
            false
        }
        return MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
            connectionState: paneState.connectionState,
            activeTransport: paneState.activeTransport,
            hasEternalTerminalRuntime: registry.runtime(for: paneId) != nil,
            hasShellOwnership: route != nil,
            transportIsLive: transportIsLive
        )
    }
    #endif

    func hasEternalTerminalCheckpoint(for paneId: UUID) -> Bool {
        eternalTerminalResumeStore.hasCheckpoint(for: paneId)
    }

    func hasMoshCheckpoint(for paneId: UUID) -> Bool {
        moshRecovery.hasCheckpoint(for: paneId)
    }

    func prepareResumableSessionsForApplicationBackground() async {
        await registry.forEachRuntime { runtime in
            await runtime.prepareForApplicationBackground()
        }
        for route in activeMoshRoutes() {
            await moshRecovery.prepareForApplicationBackground(
                for: route.paneId,
                using: route.client,
                shellId: route.shellId,
                isCurrentOwner: { [weak registry = self.registry] in
                    registry?.ownsShell(
                        client: route.client,
                        shellId: route.shellId,
                        for: route.paneId
                    ) == true
                }
            )
        }
    }

    func resumeResumableSessionsFromApplicationBackground() async {
        await registry.forEachRuntime { runtime in
            await runtime.resumeFromApplicationBackground()
        }
        for route in activeMoshRoutes() {
            await moshRecovery.resumeFromApplicationBackground(
                for: route.paneId,
                using: route.client,
                shellId: route.shellId,
                isCurrentOwner: { [weak registry = self.registry] in
                    registry?.ownsShell(
                        client: route.client,
                        shellId: route.shellId,
                        for: route.paneId
                    ) == true
                }
            )
        }
    }

    func prepareTransportForReconnect(_ paneId: UUID) async {
        logger.info("Reconnect transport cleanup pane=\(paneId.uuidString, privacy: .public)")
        registry.cancelConnectionTask(for: paneId)
        let client = registry.connectionClient(for: paneId)
        let shellId = registry.shellId(for: paneId)
        let startToken = registry.connectionStartToken(for: paneId)
        let runtime = registry.runtime(for: paneId)
        let detachedRuntime = runtime.flatMap {
            detachEternalTerminalRuntime(for: paneId, ifOwnedBy: $0) ? $0 : nil
        }

        if let client,
           !registry.hasOtherClientReferences(using: client, excluding: paneId) {
            await client.abortConnection()
        }
        detachedRuntime?.abortConnection()

        async let sshCleanup: Void = {
            if let client, let shellId {
                await unregisterSSHClient(
                    for: paneId,
                    ifOwnedBy: client,
                    shellId: shellId
                )
            } else if let startToken {
                await unregisterSSHClient(for: paneId, ifOwnedBy: startToken)
            }
        }()
        async let eternalTerminalCleanup: Void = detachedRuntime?.close() ?? ()
        _ = await (sshCleanup, eternalTerminalCleanup)
    }

    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        startToken: SSHShellRegistry.StartToken,
        for paneId: UUID,
        serverId: UUID,
        transportState: ShellTransportState = .ssh
    ) async -> Bool {
        let result = registry.registerShell(
            client: client,
            shellId: shellId,
            startToken: startToken,
            for: paneId,
            serverId: serverId
        )
        guard result == .accepted else {
            logger.warning("Ignoring stale shell registration for pane \(paneId.uuidString, privacy: .public)")
            await performTrackedConnectionCleanup(for: client) {
                await client.closeShell(shellId)
            }
            return false
        }

        logger.info(
            "Shell registered monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public) pane=\(paneId.uuidString, privacy: .public) start=\(startToken.id.uuidString, privacy: .public)"
        )
        sessionAccess.send(.activeTransport(paneId, transportState))
        return true
    }

    func unregisterSSHClient(for paneId: UUID) async {
        await unregisterSSHClient(
            for: paneId,
            killingManagedTmuxSessionNamed: nil,
            beforeCleanup: nil
        )
    }

    func unregisterSSHClient(
        for paneId: UUID,
        ifOwnedBy client: SSHClient,
        shellId: UUID
    ) async {
        guard registry.ownsShell(client: client, shellId: shellId, for: paneId) else { return }
        await unregisterSSHClient(for: paneId)
    }

    func unregisterSSHClient(
        for paneId: UUID,
        ifOwnedBy startToken: SSHShellRegistry.StartToken
    ) async {
        guard registry.ownsConnection(startToken: startToken, for: paneId) else { return }
        await unregisterSSHClient(for: paneId)
    }

    @discardableResult
    func startSSHConnectionTask(
        for paneId: UUID,
        server: Server,
        client: SSHClient,
        operation: @escaping @Sendable (TerminalSSHConnectionContext) async -> Void
    ) -> Bool {
        guard let startToken = beginShellStart(for: paneId, client: client) else {
            return false
        }

        let registry = registry
        let sessionAccess = sessionAccess
        let tmuxCoordinator = tmuxCoordinator
        let moshRecovery = moshRecovery
        let taskId = registry.startConnectionTask(for: paneId) { [weak registry, weak tmuxCoordinator] taskId in
            guard let context = await Self.makeSSHConnectionContext(
                taskId: taskId,
                startToken: startToken,
                paneId: paneId,
                server: server,
                client: client,
                registry: registry,
                sessionAccess: sessionAccess,
                tmuxCoordinator: tmuxCoordinator,
                moshRecovery: moshRecovery
            ) else { return }
            await operation(context)
            await registry?.finishShellStart(
                for: paneId,
                client: client,
                startToken: startToken
            )
        }
        guard taskId != nil else {
            registry.finishShellStart(for: paneId, client: client, startToken: startToken)
            return false
        }
        return true
    }

    func isTransportStartInFlight(for paneId: UUID) -> Bool {
        let result = registry.shellStartStatus(for: paneId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale pane shell-start in-flight flag for",
            paneId: paneId
        )
        return result.inFlight || registry.runtime(for: paneId)?.isStartInFlight == true
    }

    func isCurrentShellOwner(
        for paneId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) -> Bool {
        sessionAccess.containsPane(paneId)
            && registry.ownsConnection(
                client: client,
                startToken: startToken,
                for: paneId
            )
    }

    func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        selectedTransport(for: serverId) == .mosh ? nil : sshClient(for: serverId)
    }

    func cancelConnectionTask(for paneId: UUID) {
        registry.cancelConnectionTask(for: paneId)
    }

    func removePane(
        _ paneId: UUID,
        deletingResumableState: Bool,
        killingManagedTmuxSessionNamed tmuxSessionName: String?
    ) {
        let shellOwnership = detachSSHOwnership(for: paneId)
        let runtime = registry.runtime(for: paneId)
        if let runtime {
            _ = registry.detachRuntime(runtime, for: paneId)
        }
        if deletingResumableState {
            deleteResumableState(for: paneId)
        }

        let registry = registry
        let tmuxCoordinator = tmuxCoordinator
        Task { @MainActor in
            await Self.cleanupSSHOwnership(
                shellOwnership,
                registry: registry,
                tmuxCoordinator: tmuxCoordinator,
                killingManagedTmuxSessionNamed: tmuxSessionName,
                beforeCleanup: nil
            )
            if let runtime {
                if let tmuxSessionName {
                    await tmuxCoordinator.killSession(named: tmuxSessionName, using: runtime)
                }
                await runtime.close()
            }
        }
    }

    func beginApplicationTermination(paneIds: Set<UUID>) -> Task<Void, Never> {
        let ownedPaneIds = paneIds.union(registry.ownedPaneIds)
        for paneId in ownedPaneIds {
            registry.cancelConnectionTask(for: paneId)
        }
        // The returned task is the termination operation. Its caller awaits it,
        // so it intentionally keeps the coordinator alive until cleanup ends.
        return Task { [self] in
            await self.prepareResumableSessionsForApplicationBackground()
            for paneId in ownedPaneIds {
                await self.unregisterSSHClient(for: paneId)
                await self.unregisterEternalTerminalRuntime(for: paneId)
            }
        }
    }

    func installMoshServer(for paneId: UUID) async throws {
        guard let registration = registry.shellRegistration(for: paneId) else {
            throw SSHError.notConnected
        }
        try await remoteMosh.installMoshServer(using: registration.client)
    }

    #if DEBUG
    func setEternalTerminalResumeStoreForTesting(
        _ store: any EternalTerminalResumeStoring
    ) {
        eternalTerminalResumeStore = store
    }

    func resetForTesting() async {
        let drainedTransports = lifetime.drain()
        eternalTerminalResumeStore = defaultEternalTerminalResumeStore
        for client in drainedTransports.clients {
            await client.disconnect()
        }
        for runtime in drainedTransports.runtimes {
            await runtime.close()
        }
    }
    #endif

    private func makeEternalTerminalOwnerAccess() -> EternalTerminalRuntimeOwnerAccess {
        let registry = registry
        let sessionAccess = sessionAccess
        let tmuxCoordinator = tmuxCoordinator
        return EternalTerminalRuntimeOwnerAccess(
            isCurrent: { [weak registry] paneId, token in
                registry?.runtime(for: paneId)?.identityToken == token
            },
            startupPlan: { [weak tmuxCoordinator] paneId, serverId, client, token in
                guard let tmuxCoordinator else { throw CancellationError() }
                return try await tmuxCoordinator.eternalTerminalStartupPlan(
                    for: paneId,
                    serverId: serverId,
                    client: client,
                    runtimeToken: token
                )
            },
            resumeContext: { paneId in
                sessionAccess.paneState(paneId)?.eternalTerminalTmuxResumeContext
            },
            setResumeContext: { paneId, context in
                sessionAccess.send(.eternalTerminalResumeContext(paneId, context))
            },
            updateConnectionState: { paneId, state in
                sessionAccess.send(.connectionState(paneId, state))
            },
            markEternalTerminalTransport: { paneId in
                sessionAccess.send(.activeTransport(paneId, .eternalTerminal))
            },
            handleShellEnd: { paneId, token, reason in
                sessionAccess.send(.shellEnd(
                    paneId,
                    reason,
                    .eternalTerminal(runtimeToken: token)
                ))
            },
            unregister: { [weak registry] paneId, token in
                guard let runtime = registry?.runtime(for: paneId),
                      runtime.identityToken == token,
                      registry?.detachRuntime(runtime, for: paneId) == true else { return }
                if sessionAccess.containsPane(paneId) {
                    sessionAccess.send(.activeTransport(paneId, .ssh))
                }
                await runtime.close()
            }
        )
    }

    func beginShellStart(
        for paneId: UUID,
        client: SSHClient
    ) -> SSHShellRegistry.StartToken? {
        guard let serverId = sessionAccess.paneState(paneId)?.serverId else { return nil }
        let result = registry.beginShellStart(
            for: paneId,
            serverId: serverId,
            client: client
        )
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Recovered stale pane shell-start lock for",
            paneId: paneId
        )
        return result.token
    }

    func finishShellStart(
        for paneId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) {
        registry.finishShellStart(
            for: paneId,
            client: client,
            startToken: startToken
        )
    }

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        paneId: UUID
    ) {
        guard let staleContext else { return }
        logger.warning("\(logMessage) \(paneId.uuidString, privacy: .public)")
        tmuxCoordinator.cancelPrompt(requestId: staleContext.token.id)
        if !registry.hasClientReferences(staleContext.client) {
            let registry = registry
            Task { @MainActor [weak registry] in
                guard let registry else { return }
                await registry.performTrackedCleanup(for: staleContext.client) { [weak registry] in
                    guard registry?.hasClientReferences(staleContext.client) == false else { return }
                    await staleContext.client.disconnect()
                }
            }
        }
    }

    private func unregisterSSHClient(
        for paneId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String?,
        beforeCleanup: (@MainActor @Sendable () async -> Void)?
    ) async {
        let ownership = detachSSHOwnership(for: paneId)
        if sessionAccess.containsPane(paneId), !registry.hasLiveTransport(for: paneId) {
            sessionAccess.send(.activeTransport(paneId, .ssh))
        }
        await Self.cleanupSSHOwnership(
            ownership,
            registry: registry,
            tmuxCoordinator: tmuxCoordinator,
            killingManagedTmuxSessionNamed: tmuxSessionName,
            beforeCleanup: beforeCleanup
        )
    }

    private func performTrackedConnectionCleanup(
        for client: SSHClient,
        operation: @MainActor @Sendable @escaping () async -> Void
    ) async {
        await registry.performTrackedCleanup(for: client, operation: operation)
    }

    private func detachSSHOwnership(for paneId: UUID) -> SSHOwnership {
        registry.cancelConnectionTask(for: paneId)
        lifetime.cancelQueuedIO(for: paneId)
        let ownership = registry.unregisterShell(for: paneId)
        if let pendingStart = ownership.pendingStart {
            tmuxCoordinator.cancelPrompt(requestId: pendingStart.token.id)
        }
        return ownership
    }

    private static func cleanupSSHOwnership(
        _ ownership: SSHOwnership,
        registry: TerminalTransportRegistry<EternalTerminalRuntime>,
        tmuxCoordinator: TerminalTmuxSessionCoordinator,
        killingManagedTmuxSessionNamed tmuxSessionName: String?,
        beforeCleanup: (@MainActor @Sendable () async -> Void)?
    ) async {
        guard let registration = ownership.registration else {
            if let pendingStart = ownership.pendingStart,
               !registry.hasClientReferences(pendingStart.client) {
                await registry.performTrackedCleanup(for: pendingStart.client) {
                    if let beforeCleanup { await beforeCleanup() }
                    guard !registry.hasClientReferences(pendingStart.client) else { return }
                    await pendingStart.client.disconnect()
                }
            }
            return
        }

        await registry.performTrackedCleanup(for: registration.client) {
            if let beforeCleanup { await beforeCleanup() }
            if let tmuxSessionName {
                await tmuxCoordinator.killSession(
                    named: tmuxSessionName,
                    using: registration.client
                )
            }
            if !registry.hasClientReferences(registration.client) {
                await registration.client.disconnect()
            } else {
                await registration.client.closeShell(registration.shellId)
            }
        }
    }

    private func preferredSSHClient(
        for serverId: UUID,
        allowPendingStart: Bool
    ) -> SSHClient? {
        if let selectedTab = sessionAccess.selectedTab(serverId) {
            let paneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in paneIds {
                if let client = registry.registeredClient(for: paneId) {
                    return client
                }
            }
        }
        for tab in sessionAccess.tabs(serverId) {
            for paneId in tab.allPaneIds {
                if let client = registry.registeredClient(for: paneId) {
                    return client
                }
            }
        }
        if let client = registry.firstRegisteredClient(for: serverId) {
            return client
        }
        return allowPendingStart ? registry.firstPendingClient(for: serverId) : nil
    }

    private func selectedTransport(for serverId: UUID) -> ShellTransport {
        if let selectedTab = sessionAccess.selectedTab(serverId),
           let state = sessionAccess.paneState(selectedTab.focusedPaneId) {
            return state.activeTransport
        }
        if let connectedPane = sessionAccess.allPaneStates().first(where: {
            $0.serverId == serverId && $0.connectionState.isConnected
        }) {
            return connectedPane.activeTransport
        }
        return sessionAccess.allPaneStates().first(where: { $0.serverId == serverId })?.activeTransport ?? .ssh
    }

    private func activeMoshRoutes() -> [(paneId: UUID, client: SSHClient, shellId: UUID)] {
        sessionAccess.allPaneStates().compactMap { state in
            guard state.activeTransport == .mosh,
                  let route = registry.shellRoute(for: state.paneId) else { return nil }
            return (state.paneId, route.client, route.shellId)
        }
    }

    private func markEternalTerminalTransport(for paneId: UUID) {
        sessionAccess.send(.activeTransport(paneId, .eternalTerminal))
    }

    private func deleteResumableState(for paneId: UUID) {
        do {
            try eternalTerminalResumeStore.deleteResumeState(for: paneId)
        } catch {
            logger.error("Failed to delete ET resume credentials: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try moshRecovery.deleteCheckpoint(for: paneId)
        } catch {
            logger.error("Failed to delete Mosh recovery snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeSSHConnectionContext(
        taskId: UUID,
        startToken: SSHShellRegistry.StartToken,
        paneId: UUID,
        server: Server,
        client: SSHClient,
        registry: TerminalTransportRegistry<EternalTerminalRuntime>?,
        sessionAccess: TerminalTransportSessionAccess,
        tmuxCoordinator: TerminalTmuxSessionCoordinator?,
        moshRecovery: any TerminalMoshRecoveryServicing
    ) -> TerminalSSHConnectionContext? {
        guard let registry else { return nil }
        let ownsConnection: @MainActor @Sendable () -> Bool = { [weak registry] in
            guard let registry else { return false }
            return registry.isCurrentConnectionTask(taskId: taskId, for: paneId)
                && sessionAccess.containsPane(paneId)
                && registry.ownsConnection(
                    client: client,
                    startToken: startToken,
                    for: paneId
                )
        }
        return TerminalSSHConnectionContext(
            isCurrent: ownsConnection,
            updateConnectionState: { state in
                guard ownsConnection() else { return }
                sessionAccess.send(.connectionState(paneId, state))
            },
            startupPlan: { [weak tmuxCoordinator] in
                guard ownsConnection() else { throw CancellationError() }
                guard let tmuxCoordinator else { throw CancellationError() }
                return try await tmuxCoordinator.startupPlan(
                    for: paneId,
                    serverId: server.id,
                    client: client,
                    startToken: startToken
                )
            },
            restoreMoshShell: { cols, rows in
                guard ownsConnection(), server.connectionMode == .mosh else { return nil }
                return await moshRecovery.restoreShell(
                    for: paneId,
                    using: client,
                    cols: cols,
                    rows: rows
                )
            },
            registerShell: { [weak registry] shell in
                guard ownsConnection() else { return false }
                guard let result = registry?.registerShell(
                    client: client,
                    shellId: shell.id,
                    startToken: startToken,
                    for: paneId,
                    serverId: server.id
                ) else { return false }
                guard result == .accepted else {
                    await client.closeShell(shell.id)
                    return false
                }
                sessionAccess.send(.activeTransport(paneId, shell.transportState))
                return true
            },
            persistMoshCheckpoint: { shellId in
                guard ownsConnection() else { return }
                await moshRecovery.persistCheckpoint(
                    for: paneId,
                    using: client,
                    shellId: shellId,
                    isCurrentOwner: ownsConnection
                )
            },
            updateTitle: { title in
                guard ownsConnection() else { return }
                sessionAccess.send(.title(paneId, title))
            },
            hasOtherRegistrations: { [weak registry] in
                guard ownsConnection() else { return false }
                return registry?.hasOtherClientReferences(using: client, excluding: paneId) == true
            },
            handleShellEnd: { [weak registry] shellId, reason in
                guard ownsConnection(),
                      registry?.ownsShell(client: client, shellId: shellId, for: paneId) == true else { return }
                sessionAccess.send(.shellEnd(
                    paneId,
                    reason,
                    .ssh(client: client, shellId: shellId)
                ))
            },
            handleFailure: { failure in
                guard ownsConnection() else { return }
                sessionAccess.send(.connectionState(paneId, .failed(failure)))
            },
            workingDirectory: {
                guard ownsConnection(), sessionAccess.shouldApplyWorkingDirectory(paneId) else {
                    return nil
                }
                return sessionAccess.workingDirectory(paneId)
            }
        )
    }
}
