import Foundation
import Darwin
import os.log

extension SSHSession {
    // MARK: - Shell

    func startShell(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize? = nil,
        startupCommand: String? = nil,
        environment: RemoteEnvironment = .fallbackPOSIX,
        terminalType: RemoteTerminalType = RemoteTerminalBootstrap.defaultTerminalType
    ) async throws -> ShellHandle {
        guard isActive, let session = libssh2Session else {
            throw SSHError.notConnected
        }
        guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        let startupId = UUID()
        shellStartupsInFlight.insert(startupId)
        var pendingChannel: OpaquePointer?
        var shouldInvalidateTransport = false
        defer {
            if shouldInvalidateTransport {
                invalidateTransport()
            }
            shellStartupsInFlight.remove(startupId)
            if !isActive {
                cleanupLibssh2()
            }
        }

        do {
            // Keep the shared session nonblocking. libssh2 1.11.1 returns
            // EAGAIN when another caller owns a partial packet; yielding here
            // lets that owner finish instead of making a blocking caller spin.
            let channelToken = startupTrace?.begin(.shellChannel)
            let channel: OpaquePointer
            do {
                channel = try await openShellStartupChannel(session: session)
                pendingChannel = channel
                try validateShellStartup(session: session)
                if let channelToken { startupTrace?.end(channelToken) }
            } catch {
                if let channelToken {
                    startupTrace?.end(
                        channelToken,
                        outcome: error is CancellationError ? "cancelled" : "failed"
                    )
                }
                throw error
            }

            // Mirror Ghostty's SSH behavior so remote prompts/themes can detect
            // 24-bit color support without changing TERM compatibility.
            for variable in RemoteTerminalBootstrap.terminalEnvironment() {
                let result = try await performShellStartupCall(session: session) {
                    libssh2_channel_setenv_ex(
                        channel,
                        variable.name,
                        UInt32(variable.name.utf8.count),
                        variable.value,
                        UInt32(variable.value.utf8.count)
                    )
                }

                // Many SSH servers gate env forwarding via AcceptEnv; continue when
                // a variable is rejected so interactive sessions still start.
                if result != 0 {
                    logger.debug("Remote SSH server rejected env \(variable.name, privacy: .public): \(result)")
                }
            }

            let ptyToken = startupTrace?.begin(.ptyRequest)
            let ptyResult: Int32
            do {
                #if DEBUG
                notifyShellStartupTestHook(.ptyRequest, session: session)
                #endif
                ptyResult = try await performShellStartupCall(session: session) {
                    libssh2_channel_request_pty_ex(
                        channel,
                        terminalType.rawValue,
                        UInt32(terminalType.rawValue.utf8.count),
                        nil,
                        0,
                        wireSize.cols,
                        wireSize.rows,
                        Int32(pixelSize?.width ?? 0),
                        Int32(pixelSize?.height ?? 0)
                    )
                }
            } catch {
                if let ptyToken {
                    startupTrace?.end(
                        ptyToken,
                        outcome: error is CancellationError ? "cancelled" : "failed"
                    )
                }
                throw error
            }
            guard ptyResult == 0 else {
                if let ptyToken { startupTrace?.end(ptyToken, outcome: "failed") }
                throw SSHError.shellRequestFailed
            }
            if let ptyToken { startupTrace?.end(ptyToken) }

            let shellToken = startupTrace?.begin(.shellRequest)
            let shellResult: Int32
            do {
                #if DEBUG
                notifyShellStartupTestHook(.shellRequest, session: session)
                #endif
                switch RemoteTerminalBootstrap.launchPlan(
                    startupCommand: startupCommand,
                    environment: environment
                ) {
                case .shell:
                    shellResult = try await performShellStartupCall(session: session) {
                        libssh2_channel_process_startup(channel, "shell", 5, nil, 0)
                    }
                case .exec(let command):
                    shellResult = try await performShellStartupCall(session: session) {
                        command.withCString { pointer in
                            libssh2_channel_process_startup(
                                channel,
                                "exec",
                                4,
                                pointer,
                                UInt32(command.utf8.count)
                            )
                        }
                    }
                }
            } catch {
                if let shellToken {
                    startupTrace?.end(
                        shellToken,
                        outcome: error is CancellationError ? "cancelled" : "failed"
                    )
                }
                throw error
            }
            guard shellResult == 0 else {
                if let shellToken { startupTrace?.end(shellToken, outcome: "failed") }
                throw SSHError.shellRequestFailed
            }
            if let shellToken { startupTrace?.end(shellToken) }

            try validateShellStartup(session: session)
            logger.info("Shell started (\(cols)x\(rows))")

            let shellId = UUID()
            let output = TerminalOutputChannel()
            let stream = TerminalOutputStream(channel: output)
            shellChannels[shellId] = ShellChannelState(
                id: shellId,
                channel: channel,
                output: output
            )

            pendingChannel = nil
            startIOLoop()
            return ShellHandle(id: shellId, stream: stream)
        } catch is CancellationError {
            shouldInvalidateTransport = true
            throw CancellationError()
        } catch SSHError.notConnected {
            shouldInvalidateTransport = true
            throw SSHError.notConnected
        } catch {
            if let pendingChannel {
                if await discardShellStartupChannel(pendingChannel, session: session) {
                    #if DEBUG
                    discardedShellStartupChannelCount += 1
                    #endif
                    self.logger.debug("Discarded failed shell startup channel")
                } else {
                    shouldInvalidateTransport = true
                }
            }
            throw error
        }
    }

    private func validateShellStartup(session: OpaquePointer) throws {
        try Task.checkCancellation()
        guard isActive,
              !hasBeenCleaned,
              let currentSession = libssh2Session,
              currentSession == session,
              socket >= 0,
              atomicSocket.isUsable else {
            throw SSHError.notConnected
        }
    }

    private func waitForShellStartupRetry(session: OpaquePointer) async throws {
        try validateShellStartup(session: session)
        await waitForSocket()
        await Task.yield()
        try validateShellStartup(session: session)
    }

    private func openShellStartupChannel(session: OpaquePointer) async throws -> OpaquePointer {
        while true {
            try validateShellStartup(session: session)
            if let channel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            ) {
                return channel
            }

            let error = libssh2_session_last_errno(session)
            guard error == LIBSSH2_ERROR_EAGAIN else {
                throw SSHError.channelOpenFailed
            }
            #if DEBUG
            notifyShellStartupTestHook(.channelOpenRetry, session: session)
            #endif
            do {
                try await waitForShellStartupRetry(session: session)
            } catch {
                invalidateTransport()
                await drainAbortedChannelOpen(session: session)
                throw error
            }
        }
    }

    private func performShellStartupCall(
        session: OpaquePointer,
        operation: () -> Int32
    ) async throws -> Int32 {
        while true {
            try validateShellStartup(session: session)
            let result = operation()
            if result != LIBSSH2_ERROR_EAGAIN {
                try validateShellStartup(session: session)
                return result
            }
            do {
                try await waitForShellStartupRetry(session: session)
            } catch {
                invalidateTransport()
                await drainAbortedShellStartupCall(operation)
                throw error
            }
        }
    }

    private func drainAbortedChannelOpen(session: OpaquePointer) async {
        for _ in 0..<1_024 {
            if libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            ) != nil || libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN {
                return
            }
            await Task.yield()
        }
        logger.error("Unable to drain aborted libssh2 channel-open operation")
    }

    private func drainAbortedShellStartupCall(_ operation: () -> Int32) async {
        for _ in 0..<1_024 {
            if operation() != LIBSSH2_ERROR_EAGAIN {
                return
            }
            await Task.yield()
        }
        logger.error("Unable to drain aborted libssh2 shell-startup operation")
    }

    private func discardShellStartupChannel(
        _ channel: OpaquePointer,
        session: OpaquePointer
    ) async -> Bool {
        let closeResult = await completeActiveChannelCleanupCall(session: session) {
            libssh2_channel_close(channel)
        }
        guard closeResult == 0 else { return false }

        let freeResult = await completeActiveChannelCleanupCall(session: session) {
            libssh2_channel_free(channel)
        }
        return freeResult == 0
    }

    func completeActiveChannelCleanupCall(
        session: OpaquePointer,
        operation: () -> Int32
    ) async -> Int32 {
        await completeChannelCleanupCall(
            canContinue: {
                isActive
                    && libssh2Session == session
                    && socket >= 0
                    && atomicSocket.isUsable
            },
            operation: operation
        )
    }

    private func completeChannelCleanupCall(
        canContinue: () -> Bool,
        operation: () -> Int32
    ) async -> Int32 {
        for _ in 0..<1_024 {
            guard canContinue() else {
                return -1
            }

            let result = operation()
            if result != LIBSSH2_ERROR_EAGAIN {
                return result
            }
            await waitForSocket()
            await Task.yield()
        }
        return LIBSSH2_ERROR_EAGAIN
    }

    #if DEBUG
    func completeChannelCleanupCallForTesting(
        results: [Int32]
    ) async -> (result: Int32, callCount: Int) {
        var pendingResults = results
        var callCount = 0
        let result = await completeChannelCleanupCall(
            canContinue: { true },
            operation: {
                callCount += 1
                guard !pendingResults.isEmpty else { return 0 }
                return pendingResults.removeFirst()
            }
        )
        return (result, callCount)
    }
    #endif

    func closeShell(_ shellId: UUID) async {
        await closeShellInternal(shellId)
    }

    func flushShellOutput(_ state: ShellChannelState) async -> Bool {
        guard !state.batchBuffer.isEmpty else { return true }
        let data = state.batchBuffer
        state.batchBuffer = Data()
        return await state.output.send(data)
    }

    func closeShellInternal(
        _ shellId: UUID,
        preservesOutput: Bool = false
    ) async {
        guard let state = shellChannels.removeValue(forKey: shellId) else { return }
        if preservesOutput {
            await state.output.finish()
        } else {
            await state.output.cancel()
        }
        libssh2_channel_close(state.channel)
        libssh2_channel_free(state.channel)
    }

    func closeAllShellChannels() async {
        let states = shellChannels
        shellChannels.removeAll()
        for state in states.values {
            await state.output.cancel()
            libssh2_channel_close(state.channel)
            libssh2_channel_free(state.channel)
        }
    }

    func abandonAllShellChannels() {
        let states = shellChannels
        shellChannels.removeAll()
        for state in states.values {
            let output = state.output
            Task {
                await output.cancel()
            }
        }
    }

    // MARK: - Write

    func write(_ data: Data, to shellId: UUID) async throws {
        guard let state = shellChannels[shellId] else {
            throw SSHError.notConnected
        }

        // Copy data to array for async-safe access (withUnsafeBytes doesn't support async)
        var bytes = [UInt8](data)
        var remaining = bytes.count
        var offset = 0

        while remaining > 0 {
            // Use _ex variant since macros not available in Swift (stream_id 0 = stdin)
            let written = bytes.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let ptr = buffer.baseAddress else { return -1 }
                return Int(libssh2_channel_write_ex(
                    state.channel, 0,
                    UnsafeRawPointer(ptr.advanced(by: offset)).assumingMemoryBound(to: CChar.self),
                    remaining
                ))
            }

            if written > 0 {
                offset += written
                remaining -= written
            } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                // Would block - actually wait for socket to be ready
                await waitForSocket()
            } else {
                throw SSHError.socketError("Write failed: \(written)")
            }
        }
    }

    // MARK: - Resize

    func resize(
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize? = nil,
        for shellId: UUID
    ) async throws {
        guard let state = shellChannels[shellId] else {
            throw SSHError.notConnected
        }
        guard let wireSize = TerminalGeometryConversion.gridSize(cols: cols, rows: rows) else {
            throw SSHError.unknown("Invalid terminal size \(cols)x\(rows)")
        }

        // Use _ex variant since macros not available in Swift. The SSH session
        // is nonblocking, so an EAGAIN result has not transmitted the resize.
        while true {
            try Task.checkCancellation()
            let result = libssh2_channel_request_pty_size_ex(
                state.channel,
                wireSize.cols,
                wireSize.rows,
                Int32(pixelSize?.width ?? 0),
                Int32(pixelSize?.height ?? 0)
            )
            if result == 0 {
                return
            }
            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            logger.warning("PTY resize failed: \(result)")
            return
        }
    }
}
