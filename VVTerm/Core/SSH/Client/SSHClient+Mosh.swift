import Foundation
import os.log
import MoshCore
import MoshBootstrap

extension SSHClient {
    struct MoshShellRuntime {
        let session: MoshClientSession
        let output: TerminalOutputChannel
        let streamTask: Task<Void, Never>
    }

    struct PreparedMoshShell: Sendable {
        let session: MoshClientSession
        let pendingOps: [MoshHostOp]
    }

    struct PreparedMoshBootstrap: Sendable {
        let shell: PreparedMoshShell
        let leaseID: UUID
        let lease: RemoteMoshServerLease
    }

    func prepareMoshShellForApplicationBackground(
        _ shellId: UUID
    ) async throws -> MoshSnapshot? {
        guard let runtime = moshShells[shellId] else { return nil }
        return try await runtime.session.prepareForApplicationBackground()
    }

    func resumeMoshShellFromApplicationBackground(_ shellId: UUID) async throws {
        guard let runtime = moshShells[shellId] else { return }
        try await runtime.session.resumeFromApplicationBackground()
    }

    func moshSnapshot(for shellId: UUID) async throws -> MoshSnapshot? {
        guard let runtime = moshShells[shellId] else { return nil }
        return try await runtime.session.makeSnapshot()
    }

    // MARK: - Mosh

    func restoreMoshShell(
        from snapshot: MoshSnapshot,
        cols: Int,
        rows: Int
    ) async throws -> ShellHandle {
        guard !isAborted else { throw SSHError.notConnected }
        guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        let generation = moshRuntimeGeneration
        let restoredSession = try await MoshRestoreStartup.run(
            restore: {
                try await MoshClientSession.restore(from: snapshot)
            },
            start: { session in
                try await session.start()
            },
            resize: { session in
                try await session.enqueue(
                    .resize(cols: wireSize.cols, rows: wireSize.rows)
                )
            },
            isCurrent: {
                await self.acceptsMoshRestore(generation)
            },
            stop: { session in
                await session.stop()
            }
        )
        guard acceptsMoshRestore(generation) else {
            await restoredSession.stop()
            throw CancellationError()
        }
        return registerMoshShell(
            PreparedMoshShell(
                session: restoredSession,
                pendingOps: []
            ),
            origin: .restored
        )
    }

    private func acceptsMoshRestore(_ generation: UUID) -> Bool {
        moshRuntimeGeneration == generation && !isAborted
    }

    func prepareMoshShell(
        using expectedSession: SSHSession,
        cols: Int,
        rows: Int,
        startupCommand: String?,
        terminalType: RemoteTerminalType
    ) async throws -> PreparedMoshBootstrap {
        let configuredHost = connectedServer?.host ?? ""
        let peerHost = await expectedSession.remoteEndpointHost()
        try validateShellStartupSession(expectedSession)
        let candidateHosts = MoshEndpointCandidatePolicy.hosts(
            configuredHost: configuredHost,
            sshPeerHost: peerHost
        )
        guard !candidateHosts.isEmpty else { throw SSHError.moshInvalidEndpoint }

        let terminateServer: @Sendable (Int32) async -> Void = { pid in
            await self.moshBootstrap.terminateMoshServer(
                pid: pid,
                execute: { command, timeout in
                    try await SSHClient.runWithDeadline(
                        timeout,
                        onTimeout: { expectedSession.abort() }
                    ) {
                        try await expectedSession.execute(command)
                    }
                }
            )
        }
        let leaseID = UUID()
        let lease = RemoteMoshServerLease(terminate: terminateServer)
        pendingMoshServerLeases[leaseID] = lease

        let bootstrapToken = startupTrace?.begin(.moshBootstrap)
        let connectInfo: MoshServerConnectInfo
        do {
            connectInfo = try await moshBootstrap.bootstrapConnectInfo(
                terminalType: terminalType,
                startCommand: startupCommand,
                portRange: 60001...61000,
                execute: { command, timeout in
                    try await SSHClient.runWithDeadline(
                        timeout,
                        onTimeout: { expectedSession.abort() }
                    ) {
                        try await expectedSession.execute(command)
                    }
                }
            )
            await lease.activate(serverPID: connectInfo.serverPID)
            if let bootstrapToken {
                startupTrace?.end(
                    bootstrapToken,
                    detail: RemoteMoshManager.portClass(Int(connectInfo.port)).rawValue
                )
            }
        } catch {
            if let bootstrapToken {
                startupTrace?.end(
                    bootstrapToken,
                    outcome: "failed",
                    detail: fallbackReason(for: error).rawValue
                )
            }
            await lease.bootstrapFailed()
            pendingMoshServerLeases.removeValue(forKey: leaseID)
            throw error
        }

        do {
            let preparedShell = try await prepareMoshShellStartup(
                using: expectedSession,
                configuredHost: configuredHost,
                candidateHosts: candidateHosts,
                connectInfo: connectInfo,
                cols: cols,
                rows: rows
            )
            return PreparedMoshBootstrap(
                shell: preparedShell,
                leaseID: leaseID,
                lease: lease
            )
        } catch {
            await lease.cleanup()
            pendingMoshServerLeases.removeValue(forKey: leaseID)
            throw error
        }
    }

    func discardPreparedMoshShell(_ prepared: PreparedMoshBootstrap) async {
        await prepared.lease.cleanup()
        await prepared.shell.session.stop()
        pendingMoshServerLeases.removeValue(forKey: prepared.leaseID)
    }

    private func prepareMoshShellStartup(
        using expectedSession: SSHSession,
        configuredHost: String,
        candidateHosts: [String],
        connectInfo: MoshServerConnectInfo,
        cols: Int,
        rows: Int
    ) async throws -> PreparedMoshShell {
        try validateShellStartupSession(expectedSession)
        guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        let startupTimeout = candidateHosts.count > 1 ? Duration.seconds(4) : moshStartupTimeout
        var lastStartupError: Error?
        var moshSession: MoshClientSession?
        var pendingOps: [MoshHostOp] = []

        for host in candidateHosts {
            try validateShellStartupSession(expectedSession)
            let endpointClass = host == configuredHost ? "configured" : "ssh_peer"
            startupTrace?.record(
                .moshEndpoint,
                stageMilliseconds: 0,
                outcome: "selected",
                detail: endpointClass
            )
            let udpToken = startupTrace?.begin(.moshUDPSession)
            let endpoint = MoshEndpoint(
                host: host,
                port: connectInfo.port,
                keyBase64_22: connectInfo.key
            )
            let candidateSession = MoshClientSession(endpoint: endpoint)

            do {
                pendingOps = try await SSHClient.runWithDeadline(
                    startupTimeout,
                    onTimeout: {
                        Task { await candidateSession.stop() }
                    }
                ) {
                    try await candidateSession.start()
                    try await candidateSession.enqueue(
                        .resize(cols: wireSize.cols, rows: wireSize.rows)
                    )
                    return try await SSHClient.waitForMoshTransportReadiness {
                        await candidateSession.drainHostOps()
                    }
                }
                moshSession = candidateSession
                if let udpToken { startupTrace?.end(udpToken, detail: endpointClass) }
                if host != configuredHost {
                    logger.info("Using SSH peer endpoint for Mosh: \(host, privacy: .private(mask: .hash))")
                }
                break
            } catch {
                await candidateSession.stop()
                if let udpToken {
                    startupTrace?.end(udpToken, outcome: "failed", detail: endpointClass)
                }
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastStartupError = error
                if host != candidateHosts.last {
                    logger.warning("Mosh startup failed for endpoint \(host, privacy: .private(mask: .hash)), trying next candidate")
                }
            }
        }

        guard let moshSession else {
            if let sshError = lastStartupError as? SSHError,
               case .timeout = sshError {
                throw SSHError.moshUDPTimeout
            }
            if let lastStartupError {
                throw SSHError.moshClientSessionFailed(lastStartupError.localizedDescription)
            }
            throw SSHError.moshClientSessionFailed("Failed to start Mosh session")
        }

        do {
            try validateShellStartupSession(expectedSession)
            return PreparedMoshShell(
                session: moshSession,
                pendingOps: pendingOps
            )
        } catch {
            await moshSession.stop()
            throw error
        }
    }

    func registerMoshShell(
        _ prepared: PreparedMoshShell,
        origin: ShellStartOrigin = .fresh
    ) -> ShellHandle {
        let shellId = UUID()
        if !prepared.pendingOps.isEmpty {
            logger.info("Mosh: \(prepared.pendingOps.count) pending host ops before stream creation")
        }

        let output = TerminalOutputChannel(overflowPolicy: .rejectNewData)
        let moshLogger = logger
        let trace = startupTrace
        let streamTask = Task { [weak self] in
            var totalBytes = 0
            var shouldContinue = true

            for op in prepared.pendingOps {
                guard !Task.isCancelled,
                      let bytes = MoshStartupReadiness.visibleTerminalBytes(from: op) else {
                    continue
                }
                trace?.recordOnce(.firstTerminalByte, detail: "mosh")
                guard await output.send(bytes) else {
                    shouldContinue = false
                    break
                }
                let (newTotal, overflow) = totalBytes.addingReportingOverflow(bytes.count)
                totalBytes = overflow ? Int.max : newTotal
            }

            while shouldContinue, !Task.isCancelled {
                let hostOps = await prepared.session.drainHostOps()
                for hostOp in hostOps {
                    guard !Task.isCancelled else {
                        shouldContinue = false
                        break
                    }
                    if let bytes = MoshStartupReadiness.visibleTerminalBytes(from: hostOp) {
                        trace?.recordOnce(.firstTerminalByte, detail: "mosh")
                        guard await output.send(bytes) else {
                            shouldContinue = false
                            break
                        }
                        let (newTotal, overflow) = totalBytes.addingReportingOverflow(bytes.count)
                        totalBytes = overflow ? Int.max : newTotal
                        moshLogger.debug("Mosh host bytes: \(bytes.count)B (total: \(totalBytes))")
                    }
                }

                guard shouldContinue, !Task.isCancelled else { break }
                if hostOps.isEmpty {
                    switch await prepared.session.state {
                    case .idle, .stopped, .failed:
                        shouldContinue = false
                    case .starting, .running, .suspending, .suspended, .stopping:
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            if !Task.isCancelled {
                await output.finish()
                moshLogger.info("Mosh stream ended, total bytes delivered: \(totalBytes)")
                await self?.moshOutputDidFinish(shellId)
            } else {
                await output.cancel()
            }
        }

        moshShells[shellId] = MoshShellRuntime(
            session: prepared.session,
            output: output,
            streamTask: streamTask
        )

        return ShellHandle(
            id: shellId,
            stream: TerminalOutputStream(channel: output),
            transportState: .mosh,
            origin: origin
        )
    }

    private func moshOutputDidFinish(_ shellId: UUID) async {
        guard let runtime = moshShells.removeValue(forKey: shellId) else { return }
        await runtime.session.stop()
    }

    nonisolated static func waitForMoshTransportReadiness(
        pollInterval: Duration = .milliseconds(20),
        draining drainHostOps: @escaping @Sendable () async -> [MoshHostOp]
    ) async throws -> [MoshHostOp] {
        while true {
            try Task.checkCancellation()
            let drained = await drainHostOps()
            if MoshStartupReadiness.isTransportEstablished(by: drained) {
                return drained
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    func fallbackReason(for error: Error) -> MoshFallbackReason {
        guard let sshError = error as? SSHError else {
            return .sessionFailed
        }

        switch sshError {
        case .moshServerMissing:
            return .serverMissing
        case .moshServerRuntimeBroken:
            return .serverRuntimeBroken
        case .moshBootstrapFailed:
            return .bootstrapFailed
        case .moshInvalidEndpoint:
            return .invalidEndpoint
        case .moshUDPTimeout:
            return .udpTimeout
        case .moshClientSessionFailed:
            return .clientSessionFailed
        case .moshSessionFailed:
            return .sessionFailed
        default:
            return .sessionFailed
        }
    }
}
