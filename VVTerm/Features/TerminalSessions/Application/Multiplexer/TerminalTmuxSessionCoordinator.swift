import Combine
import Foundation
import os.log

nonisolated struct TerminalTmuxAttachmentState: Codable, Equatable, Sendable {
    let sessionName: String
    let ownership: TmuxSessionOwnership
    let managedSessionConfirmed: Bool?
}

@MainActor
struct TerminalTmuxShellRegistration {
    let client: SSHClient
    let shellId: UUID
    let serverId: UUID
}

/// Owns tmux attachment state, prompt lifetime, startup planning, installation,
/// cleanup, and remote-session termination for terminal panes.
@MainActor
final class TerminalTmuxSessionCoordinator: ObservableObject {
    private enum InstallOutcome: Sendable {
        case installed(sessionName: String)
        case unavailable
        case missing
        case indeterminate
    }

    var attachPrompt: TmuxAttachPrompt? {
        resolver.currentPrompt
    }

    private let configuration: TerminalTmuxConfiguration
    private let remoteTmux: any TerminalRemoteTmuxServicing
    private let resolver: TmuxAttachResolver
    private let sessionState: TerminalSessionStateStore
    private let transportLifetime: TerminalTransportLifetime
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "TerminalTmuxSessionCoordinator"
    )
    private var cleanupServers: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        configuration: TerminalTmuxConfiguration,
        remoteTmux: any TerminalRemoteTmuxServicing,
        resolver: TmuxAttachResolver,
        sessionState: TerminalSessionStateStore,
        transportLifetime: TerminalTransportLifetime
    ) {
        self.configuration = configuration
        self.remoteTmux = remoteTmux
        self.resolver = resolver
        self.sessionState = sessionState
        self.transportLifetime = transportLifetime
        resolver.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Settings and attachment state

    var enabledByDefault: Bool {
        resolver.tmuxEnabledDefault
    }

    var startupBehaviorByDefault: TmuxStartupBehavior {
        resolver.tmuxStartupBehaviorDefault
    }

    func isEnabled(for serverId: UUID) -> Bool {
        resolver.isTmuxEnabled(for: serverId)
    }

    func startupBehavior(for serverId: UUID) -> TmuxStartupBehavior {
        resolver.tmuxStartupBehavior(for: serverId)
    }

    func managedSessionName(for paneId: UUID) -> String {
        resolver.managedSessionName(for: paneId)
    }

    func sessionName(for paneId: UUID) -> String {
        resolver.sessionName(for: paneId)
    }

    func attachment(for paneId: UUID) -> TerminalTmuxAttachmentState? {
        resolver.attachment(for: paneId)
    }

    func restoreAttachments(_ attachments: [UUID: TerminalTmuxAttachmentState]) {
        resolver.restoreAttachments(attachments)
    }

    func clearAllAttachmentState() {
        resolver.clearAllAttachmentState()
    }

    func setAttachment(
        for paneId: UUID,
        sessionName: String,
        ownership: TmuxSessionOwnership,
        managedSessionConfirmed: Bool = false
    ) {
        resolver.sessionNames[paneId] = sessionName
        resolver.sessionOwnership[paneId] = ownership
        if managedSessionConfirmed {
            resolver.confirmManagedSession(for: paneId)
        }
    }

    func clearAttachmentState(for paneId: UUID) {
        resolver.clearAttachmentState(for: paneId)
    }

    func updateAttachmentState(for paneId: UUID, selection: TmuxAttachSelection) {
        resolver.updateAttachmentState(
            for: paneId,
            selection: selection
        )
    }

    func confirmManagedSession(for paneId: UUID) {
        resolver.confirmManagedSession(for: paneId)
    }

    func hasConfirmedManagedSession(for paneId: UUID) -> Bool {
        resolver.hasConfirmedManagedSession(for: paneId)
    }

    func shouldReattachManagedSession(for paneId: UUID) -> Bool {
        resolver.sessionOwnership[paneId] == .managed
            && resolver.sessionNames[paneId] != nil
            && resolver.hasConfirmedManagedSession(for: paneId)
    }

    // MARK: - Prompt ownership

    func resolvePrompt(requestId: UUID, selection: TmuxAttachSelection) {
        resolver.resolvePrompt(
            requestId: requestId,
            selection: selection
        )
    }

    func cancelPrompt(requestId: UUID) {
        resolver.cancelPrompt(requestId: requestId)
    }

    func hasPendingPrompt(requestId: UUID) -> Bool {
        resolver.hasPendingPrompt(requestId: requestId)
    }

    func requestSelection(
        requestId: UUID,
        paneId: UUID,
        serverId: UUID,
        availableSessions: [TmuxAttachSessionInfo]
    ) async -> TmuxAttachSelection {
        await resolver.requestSelection(
            requestId: requestId,
            entityId: paneId,
            serverId: serverId,
            availableSessions: availableSessions
        )
    }

    func resolveSelection(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        backend: RemoteTmuxBackend,
        requestId: UUID,
        validateOwner: () throws -> Void
    ) async throws -> TmuxAttachSelection {
        try await resolver.resolveSelection(
            for: paneId,
            serverId: serverId,
            client: client,
            backend: backend,
            requestId: requestId,
            validateOwner: validateOwner
        )
    }

    func sessionInfosForPrompt(from sessions: [RemoteTmuxSession]) -> [TmuxAttachSessionInfo] {
        resolver.sessionInfosForPrompt(from: sessions)
    }

    func isInternalSessionName(_ name: String) -> Bool {
        resolver.isInternalSessionName(name)
    }

    func isCurrentDeviceManagedSessionName(_ name: String) -> Bool {
        resolver.isCurrentDeviceManagedSessionName(name)
    }

    func cancelPrompt(for startContext: SSHShellRegistry.StartContext?) {
        guard let startContext else { return }
        cancelPrompt(requestId: startContext.token.id)
    }

    func clearRuntimeState(for paneId: UUID) {
        resolver.clearRuntimeState(for: paneId)
    }

    // MARK: - Pane state

    func status(for paneId: UUID) -> TmuxStatus? {
        sessionState.paneState(for: paneId)?.tmuxStatus
    }

    func updateStatus(_ status: TmuxStatus, for paneId: UUID) {
        guard let previousStatus = sessionState.paneState(for: paneId)?.tmuxStatus,
              previousStatus != status else { return }
        sessionState.updatePane(paneId) { $0.tmuxStatus = status }
        logger.info(
            "Tmux status for pane \(paneId.uuidString, privacy: .public) changed from \(previousStatus.rawValue, privacy: .public) to \(status.rawValue, privacy: .public)"
        )
    }

    func shouldApplyWorkingDirectory(for paneId: UUID) -> Bool {
        guard let status = status(for: paneId) else { return false }
        return status == .off || status == .missing
    }

    func updateSelectionStatuses(selectedTabs: [UUID: UUID]) {
        for serverId in sessionState.serverIdsWithTabs {
            for tab in sessionState.tabs(for: serverId) {
                updateFocus(
                    for: tab,
                    isSelectedTab: selectedTabs[serverId] == tab.id
                )
            }
        }
    }

    func updateFocus(for tab: TerminalTab) {
        updateFocus(
            for: tab,
            isSelectedTab: sessionState.selectedTabId(for: tab.serverId) == tab.id
        )
    }

    private func updateFocus(for tab: TerminalTab, isSelectedTab: Bool) {
        for paneId in tab.allPaneIds {
            guard let state = sessionState.paneState(for: paneId),
                  state.tmuxStatus == .foreground || state.tmuxStatus == .background else {
                continue
            }
            let newStatus: TmuxStatus = (isSelectedTab && tab.focusedPaneId == paneId)
                ? .foreground
                : .background
            updateStatus(newStatus, for: paneId)
        }
    }

    func disable(for serverId: UUID) {
        for state in sessionState.paneStates(forServer: serverId) {
            updateStatus(.off, for: state.paneId)
            clearRuntimeState(for: state.paneId)
        }
    }

    // MARK: - Startup planning

    func startupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken,
        availabilityResolver: (() async -> RemoteTmuxAvailability)? = nil,
        transport: ShellTransport = .ssh
    ) async throws -> TerminalShellStartupPlan {
        try await startupPlan(
            for: paneId,
            serverId: serverId,
            client: client,
            availabilityResolver: availabilityResolver ?? {
                await self.remoteTmux.tmuxAvailability(using: client)
            },
            transport: transport,
            requestId: startToken.id,
            validateOwner: {
                try self.requireCurrentShellOwner(
                    for: paneId,
                    client: client,
                    startToken: startToken
                )
            }
        )
    }

    func eternalTerminalStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        runtimeToken: UUID
    ) async throws -> TerminalShellStartupPlan {
        let plan = try await startupPlan(
            for: paneId,
            serverId: serverId,
            client: client,
            availabilityResolver: {
                await self.remoteTmux.tmuxAvailability(using: client)
            },
            transport: .eternalTerminal,
            requestId: runtimeToken,
            validateOwner: {
                try Task.checkCancellation()
                guard self.transportLifetime.registry.runtime(for: paneId)?.identityToken
                    == runtimeToken else {
                    throw CancellationError()
                }
            }
        )
        if let command = plan.command, plan.tmuxLifecycle != nil {
            try Task.checkCancellation()
            guard transportLifetime.registry.runtime(for: paneId)?.identityToken
                == runtimeToken else {
                throw CancellationError()
            }

            let remotePath = EternalTerminalStartupCommand.remoteScriptPath(token: runtimeToken)
            let script = EternalTerminalStartupCommand.script(
                command: command,
                remotePath: remotePath
            )
            try await client.upload(
                Data(script.utf8),
                to: remotePath,
                permissions: 0o700
            )
            return TerminalShellStartupPlan(
                command: EternalTerminalStartupCommand.invocation(remotePath: remotePath),
                tmuxLifecycle: plan.tmuxLifecycle
            )
        }

        guard plan.command == nil,
              let workingDirectory = sessionState.paneState(for: paneId)?.workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return plan
        }

        let environment = await client.remoteEnvironment()
        let restorePlan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: workingDirectory,
            environment: environment
        )
        guard case .command(let command) = restorePlan else {
            if case .keepDefault(let reason) = restorePlan {
                logger.warning(
                    "Keeping the default ET directory [reason: \(reason.rawValue, privacy: .public)]"
                )
            }
            return plan
        }
        return TerminalShellStartupPlan(command: command, tmuxLifecycle: nil)
    }

    private func startupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        availabilityResolver: () async -> RemoteTmuxAvailability,
        transport: ShellTransport,
        requestId: UUID,
        validateOwner: () throws -> Void
    ) async throws -> TerminalShellStartupPlan {
        try validateOwner()

        guard isEnabled(for: serverId) else {
            disableAttachment(for: paneId, status: .off)
            return .plainShell
        }

        let availability = await availabilityResolver()
        try validateOwner()

        let backend: RemoteTmuxBackend
        switch availability {
        case .unsupported:
            disableAttachment(for: paneId, status: .off)
            return .plainShell
        case .available(let availableBackend):
            backend = availableBackend
        case .confirmedMissing:
            disableAttachment(for: paneId, status: .missing)
            return .plainShell
        case .indeterminate(let failure):
            logger.warning(
                "Preserving tmux attachment for pane \(paneId.uuidString, privacy: .public) after indeterminate probe: \(failure.logDescription, privacy: .public)"
            )
            throw failure.retryError
        }

        let isReattachingManagedSession = shouldReattachManagedSession(for: paneId)
        let selection = try await resolveSelection(
            for: paneId,
            serverId: serverId,
            client: client,
            backend: backend,
            requestId: requestId,
            validateOwner: validateOwner
        )
        try validateOwner()
        updateAttachmentState(for: paneId, selection: selection)
        sessionState.requestPersistence()

        if case .skipTmux = selection {
            updateStatus(.off, for: paneId)
            return .plainShell
        }

        await runCleanupIfNeeded(
            for: serverId,
            paneId: paneId,
            selection: selection,
            using: client,
            backend: backend
        )
        try validateOwner()
        await prepareActivePane(
            for: paneId,
            serverId: serverId,
            using: client,
            backend: backend
        )
        try validateOwner()

        let workingDirectory = await resolveWorkingDirectory(
            for: paneId,
            using: client,
            backend: backend
        )
        try validateOwner()
        if workingDirectory != "~" {
            sessionState.updatePane(paneId) { $0.workingDirectory = workingDirectory }
        }
        guard let ownership = resolver.sessionOwnership[paneId] else {
            throw SSHError.unknown("tmux attachment state was lost during startup")
        }
        let lifecycleMarkerToken = UUID().uuidString
        let sessionName = resolver.sessionName(for: paneId)
        let presenceToken = UUID().uuidString
        let existsMarker = "__VVTERM_TMUX_EXISTS_\(presenceToken)__"
        let missingMarker = "__VVTERM_TMUX_MISSING_\(presenceToken)__"
        return TerminalShellStartupPlan(
            command: startupCommand(
                for: paneId,
                selection: selection,
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                ownership: ownership,
                reattachingManagedSession: isReattachingManagedSession,
                transport: transport
            ),
            tmuxLifecycle: TmuxShellLifecycleContext(
                ownership: ownership,
                markerToken: lifecycleMarkerToken,
                presenceProbe: TmuxSessionPresenceProbe(
                    command: RemoteTmuxCommandBuilder.sessionPresenceProbeCommand(
                        sessionName: sessionName,
                        backend: backend,
                        existsMarker: existsMarker,
                        missingMarker: missingMarker
                    ),
                    existsMarker: existsMarker,
                    missingMarker: missingMarker
                )
            )
        )
    }

    private func requireCurrentShellOwner(
        for paneId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) throws {
        try Task.checkCancellation()
        guard sessionState.containsPane(paneId),
              transportLifetime.registry.ownsConnection(
                  client: client,
                  startToken: startToken,
                  for: paneId
              ) else {
            logger.info("Ignoring stale tmux startup result for pane \(paneId.uuidString, privacy: .public)")
            throw CancellationError()
        }
    }

    private func disableAttachment(for paneId: UUID, status: TmuxStatus) {
        resolver.clearAttachmentState(for: paneId)
        updateStatus(status, for: paneId)
    }

    private func managedSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for tab in sessionState.tabs(for: serverId) {
            for paneId in tab.allPaneIds {
                let ownership = resolver.sessionOwnership[paneId] ?? .managed
                guard ownership == .managed else { continue }
                names.insert(resolver.sessionName(for: paneId))
            }
        }
        return names
    }

    private func sessionNamesToKeep(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(resolver.sessionName(for: paneId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func runCleanupIfNeeded(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        guard cleanupServers.insert(serverId).inserted else { return }
        await remoteTmux.cleanupLegacySessions(using: client, backend: backend)
        await remoteTmux.cleanupDetachedSessions(
            deviceId: configuration.deviceID,
            keeping: sessionNamesToKeep(
                for: serverId,
                paneId: paneId,
                selection: selection
            ),
            using: client,
            backend: backend
        )
    }

    private func prepareActivePane(
        for paneId: UUID,
        serverId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        let selectedTab = sessionState.selectedTab(for: serverId)
        let selectedTabId = sessionState.selectedTabId(for: serverId)
        let isForeground = selectedTab?.id == selectedTabId
            && selectedTab?.focusedPaneId == paneId
        updateStatus(isForeground ? .foreground : .background, for: paneId)
        let terminalType = await client.remoteTerminalType()
        await remoteTmux.prepareConfig(
            using: client,
            terminalType: terminalType,
            themeStyle: configuration.themeStyle(),
            backend: backend
        )
    }

    private func startupCommand(
        for paneId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        lifecycleMarkerToken: String,
        ownership: TmuxSessionOwnership,
        reattachingManagedSession: Bool,
        transport: ShellTransport
    ) -> String? {
        let themeStyle = configuration.themeStyle()
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            if reattachingManagedSession {
                return RemoteTmuxCommandBuilder.attachExistingCommand(
                    themeStyle: themeStyle,
                    sessionName: resolver.sessionName(for: paneId),
                    ownership: .managed,
                    backend: backend,
                    lifecycleMarkerToken: lifecycleMarkerToken,
                    transport: transport
                )
            }
            return RemoteTmuxCommandBuilder.attachCommand(
                themeStyle: themeStyle,
                sessionName: resolver.sessionName(for: paneId),
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                transport: transport
            )
        case .attachExisting(let sessionName):
            return RemoteTmuxCommandBuilder.attachExistingCommand(
                themeStyle: themeStyle,
                sessionName: sessionName,
                ownership: ownership,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                transport: transport
            )
        }
    }

    private func resolveWorkingDirectory(
        for paneId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend? = nil
    ) async -> String {
        if let seedPaneId = sessionState.paneState(for: paneId)?.seedPaneId,
           let path = await remoteTmux.currentPath(
               sessionName: resolver.sessionName(for: seedPaneId),
               using: client,
               backend: backend
           ) {
            return path
        }

        if let path = await remoteTmux.currentPath(
            sessionName: resolver.sessionName(for: paneId),
            using: client,
            backend: backend
        ) {
            return path
        }

        if let candidate = sessionState.paneState(for: paneId)?.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }
        return "~"
    }

    // MARK: - Installation and cleanup

    func startInstall(
        for paneId: UUID,
        onInstalled: @MainActor @escaping () -> Void
    ) async {
        if let runtime = transportLifetime.registry.runtime(for: paneId) {
            await startEternalTerminalInstall(
                for: paneId,
                runtime: runtime,
                onInstalled: onInstalled
            )
            return
        }

        guard let registration = shellRegistration(for: paneId),
              isEnabled(for: registration.serverId) else { return }

        updateStatus(.installing, for: paneId)
        do {
            let outcome = try await performInstall(
                for: paneId,
                using: registration.client,
                sendScript: { script in
                    try await self.remoteTmux.sendScript(
                        script,
                        using: registration.client,
                        shellId: registration.shellId
                    )
                },
                validateOwner: {
                    self.ownsShell(registration, for: paneId)
                }
            )
            guard ownsShell(registration, for: paneId) else { return }
            await finishInstall(
                outcome,
                for: paneId,
                onInstalled: onInstalled,
                beforeReconnect: {
                    await self.transportLifetime.unregisterShell(
                        for: paneId,
                        ifOwnedBy: registration
                    )
                }
            )
        } catch is CancellationError {
            return
        } catch {
            guard ownsShell(registration, for: paneId) else { return }
            logger.warning("tmux installation failed: \(error.localizedDescription, privacy: .public)")
            updateStatus(.unknown, for: paneId)
        }
    }

    private func startEternalTerminalInstall(
        for paneId: UUID,
        runtime: EternalTerminalRuntime,
        onInstalled: @MainActor @escaping () -> Void
    ) async {
        guard let serverId = sessionState.paneState(for: paneId)?.serverId,
              isEnabled(for: serverId),
              transportLifetime.registry.isCurrentRuntime(runtime, for: paneId) else { return }

        updateStatus(.installing, for: paneId)
        do {
            let outcome = try await runtime.withBootstrapSSHClient { client in
                try await self.performInstall(
                    for: paneId,
                    using: client,
                    sendScript: { script in
                        try await runtime.sendInteractiveScript(script)
                    },
                    validateOwner: {
                        self.transportLifetime.registry.isCurrentRuntime(runtime, for: paneId)
                    }
                )
            }
            guard transportLifetime.registry.isCurrentRuntime(runtime, for: paneId) else { return }
            await finishInstall(
                outcome,
                for: paneId,
                onInstalled: onInstalled,
                beforeReconnect: {
                    if await self.transportLifetime.unregisterRuntime(
                        for: paneId,
                        ifOwnedBy: runtime
                    ) {
                        self.sessionState.updatePane(paneId) { $0.transportState = .ssh }
                    }
                }
            )
        } catch is CancellationError {
            return
        } catch {
            guard transportLifetime.registry.isCurrentRuntime(runtime, for: paneId) else { return }
            logger.warning("ET tmux installation failed: \(error.localizedDescription, privacy: .public)")
            updateStatus(.unknown, for: paneId)
        }
    }

    private func performInstall(
        for paneId: UUID,
        using client: SSHClient,
        sendScript: @MainActor @Sendable (String) async throws -> Void,
        validateOwner: @MainActor @Sendable () -> Bool
    ) async throws -> InstallOutcome {
        guard let backend = await remoteTmux.tmuxInstallBackend(using: client) else {
            return .unavailable
        }
        try Task.checkCancellation()
        guard validateOwner() else { throw CancellationError() }

        let sessionName = resolver.sessionName(for: paneId)
        let workingDirectory = await resolveWorkingDirectory(
            for: paneId,
            using: client,
            backend: backend
        )
        try Task.checkCancellation()
        guard validateOwner() else { throw CancellationError() }

        let terminalType = await client.remoteTerminalType()
        try Task.checkCancellation()
        guard validateOwner() else { throw CancellationError() }

        let script = RemoteTmuxCommandBuilder.installAndAttachScript(
            themeStyle: configuration.themeStyle(),
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            backend: backend,
            attachAfterInstall: false
        )
        try await sendScript(script)

        var observedIndeterminateResult = false
        for _ in 0..<6 {
            try await Task.sleep(for: .seconds(2))
            guard validateOwner() else { throw CancellationError() }
            let availability = await remoteTmux.tmuxAvailability(using: client)
            try Task.checkCancellation()
            guard validateOwner() else { throw CancellationError() }

            switch availability {
            case .available:
                return .installed(sessionName: sessionName)
            case .confirmedMissing:
                continue
            case .indeterminate:
                observedIndeterminateResult = true
            case .unsupported:
                return .unavailable
            }
        }
        return observedIndeterminateResult ? .indeterminate : .missing
    }

    private func finishInstall(
        _ outcome: InstallOutcome,
        for paneId: UUID,
        onInstalled: @MainActor @escaping () -> Void,
        beforeReconnect: @MainActor @Sendable () async -> Void
    ) async {
        switch outcome {
        case .installed(let sessionName):
            await beforeReconnect()
            completeInstall(
                for: paneId,
                sessionName: sessionName,
                onInstalled: onInstalled
            )
        case .unavailable:
            updateStatus(.off, for: paneId)
        case .missing:
            updateStatus(.missing, for: paneId)
        case .indeterminate:
            updateStatus(.unknown, for: paneId)
        }
    }

    func completeInstall(
        for paneId: UUID,
        sessionName: String,
        onInstalled: () -> Void
    ) {
        guard sessionState.containsPane(paneId) else { return }
        resolver.clearAttachmentState(for: paneId)
        resolver.sessionNames[paneId] = sessionName
        resolver.sessionOwnership[paneId] = .managed
        sessionState.requestPersistence()
        onInstalled()
    }

    func managedSessionNameToKill(for paneId: UUID, status: TmuxStatus) -> String? {
        guard status == .foreground || status == .background || status == .installing else {
            return nil
        }
        let ownership = resolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return nil }
        return resolver.sessionName(for: paneId)
    }

    func killIfNeeded(for paneId: UUID) {
        guard let registration = shellRegistration(for: paneId) else { return }
        let ownership = resolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = resolver.sessionName(for: paneId)
        Task.detached { [remoteTmux, sessionName, client = registration.client] in
            await remoteTmux.killSession(
                named: sessionName,
                using: client,
                backend: nil
            )
        }
    }

    func killSession(named sessionName: String, using client: SSHClient) async {
        await remoteTmux.killSession(named: sessionName, using: client, backend: nil)
    }

    func killSession(named sessionName: String, using runtime: EternalTerminalRuntime) async {
        await runtime.killManagedTmuxSession(named: sessionName)
    }

    func resetRuntimeState(for paneIds: Set<UUID>) {
        for paneId in paneIds {
            clearRuntimeState(for: paneId)
        }
        resolver.cancelAllPrompts()
        cleanupServers.removeAll()
    }

    private func shellRegistration(for paneId: UUID) -> TerminalTmuxShellRegistration? {
        transportLifetime.registry.shellRegistration(for: paneId).map {
            TerminalTmuxShellRegistration(
                client: $0.client,
                shellId: $0.shellId,
                serverId: $0.serverId
            )
        }
    }

    private func ownsShell(
        _ registration: TerminalTmuxShellRegistration,
        for paneId: UUID
    ) -> Bool {
        transportLifetime.registry.ownsShell(
            client: registration.client,
            shellId: registration.shellId,
            for: paneId
        )
    }
}

#if DEBUG
extension TerminalTmuxSessionCoordinator {
    convenience init() {
        let configuration = TerminalTmuxConfiguration.testing
        let remoteTmux = UnavailableTerminalRemoteTmuxService()
        let resolver = TmuxAttachResolver(
            configuration: configuration,
            remoteTmux: remoteTmux
        )
        let sessionState = TerminalSessionStateStore(
            snapshotStore: EmptyTerminalTabSnapshotStore(),
            connectionViewSelections: ConnectionViewSelectionStore(),
            tmuxResolver: resolver
        )
        self.init(
            configuration: configuration,
            remoteTmux: remoteTmux,
            resolver: resolver,
            sessionState: sessionState,
            transportLifetime: TerminalTransportLifetime()
        )
    }
}

@MainActor
private final class EmptyTerminalTabSnapshotStore: TerminalTabSnapshotStoring {
    func loadSnapshotData() -> Data? { nil }
    func saveSnapshotData(_ data: Data) {}
    func removeSnapshotData() {}
}

extension TerminalTmuxConfiguration {
    static var testing: Self {
        Self(
            deviceID: "test-device",
            enabledByDefault: { true },
            startupBehaviorByDefault: { .askEveryTime },
            serverSettings: { _ in nil },
            themeStyle: {
                RemoteTmuxThemeStyle(name: "Aizen Dark", modeStyle: "bg=default,fg=default")
            }
        )
    }
}

actor UnavailableTerminalRemoteTmuxService: TerminalRemoteTmuxServicing {
    func tmuxAvailability(using client: SSHClient) async -> RemoteTmuxAvailability { .unsupported }
    func tmuxInstallBackend(using client: SSHClient) async -> RemoteTmuxBackend? { nil }
    func listSessions(
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async throws -> [RemoteTmuxSession] { throw SSHError.notConnected }
    func prepareConfig(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteTmuxThemeStyle,
        backend: RemoteTmuxBackend?
    ) async {}
    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async throws {
        throw SSHError.notConnected
    }
    func killSession(named sessionName: String, using client: SSHClient, backend: RemoteTmuxBackend?) async {}
    func cleanupLegacySessions(using client: SSHClient, backend: RemoteTmuxBackend?) async {}
    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async {}
    func currentPath(
        sessionName: String,
        using client: SSHClient,
        backend: RemoteTmuxBackend?
    ) async -> String? { nil }
}
#endif
