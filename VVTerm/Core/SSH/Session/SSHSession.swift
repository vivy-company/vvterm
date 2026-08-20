import Foundation
import Darwin
import os.log

// MARK: - SSH Session using libssh2

actor SSHSession {
    #if DEBUG
    struct ShellStartupTestEvent: Sendable {
        let stage: ShellStartupStage
        let sessionIsBlocking: Bool
    }
    #endif

    final class ExecRequest {
        let id: UUID
        let command: String
        let continuation: CheckedContinuation<String, Error>
        var channel: OpaquePointer?
        var output = Data()
        var stderr = Data()
        var outputBudget: SSHExecOutputBudget
        var isStarted = false

        init(
            id: UUID,
            command: String,
            maximumOutputBytes: Int,
            continuation: CheckedContinuation<String, Error>
        ) {
            self.id = id
            self.command = command
            self.outputBudget = SSHExecOutputBudget(maximumBytes: maximumOutputBytes)
            self.continuation = continuation
        }
    }

    final class ShellChannelState {
        let id: UUID
        var channel: OpaquePointer
        let output: TerminalOutputChannel
        var batchBuffer = Data()
        var lastYieldTime: UInt64 = DispatchTime.now().uptimeNanoseconds
        var recentBytesPerRead: Int = 0
        var didRecordFirstByte = false

        init(id: UUID, channel: OpaquePointer, output: TerminalOutputChannel) {
            self.id = id
            self.channel = channel
            self.output = output
        }
    }

    let config: SSHSessionConfig
    let hostKeyVerifier: any SSHHostKeyVerifying
    var libssh2Session: OpaquePointer?
    var sftpSession: OpaquePointer?
    var shellChannels: [UUID: ShellChannelState] = [:]
    var shellStartupsInFlight: Set<UUID> = []
    var socket: Int32 = -1
    var isActive = false
    var ioTask: Task<Void, Never>?
    var execRequests: [UUID: ExecRequest] = [:]
    var connectedPeerAddress: String?
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHSession")
    let startupTrace: SSHStartupTrace?

    /// Atomic socket storage for emergency abort from any thread
    let atomicSocket = AtomicSocket()

    /// Session-specific auth callback context passed to libssh2 session abstract pointer.
    let keyboardInteractiveContext = KeyboardInteractiveContext()

    /// Track if cleanup has been performed
    var hasBeenCleaned = false

    #if DEBUG
    var shellStartupTestHook: (@Sendable (ShellStartupTestEvent) -> Void)?
    var discardedShellStartupChannelCount = 0
    #endif

    init(
        config: SSHSessionConfig,
        hostKeyVerifier: any SSHHostKeyVerifying,
        startupTrace: SSHStartupTrace? = nil
    ) {
        self.config = config
        self.hostKeyVerifier = hostKeyVerifier
        self.startupTrace = startupTrace
    }

    var isConnected: Bool {
        isActive && libssh2Session != nil
    }

    /// Interrupt socket I/O from any thread; actor-owned cleanup performs the final close.
    nonisolated func abort() {
        atomicSocket.interrupt()
    }

    #if DEBUG
    func setShellStartupTestHook(
        _ hook: (@Sendable (ShellStartupTestEvent) -> Void)?
    ) {
        shellStartupTestHook = hook
    }

    func discardedShellStartupChannelsForTesting() -> Int {
        discardedShellStartupChannelCount
    }

    func notifyShellStartupTestHook(
        _ stage: ShellStartupStage,
        session: OpaquePointer
    ) {
        shellStartupTestHook?(
            ShellStartupTestEvent(
                stage: stage,
                sessionIsBlocking: libssh2_session_get_blocking(session) != 0
            )
        )
    }
    #endif

    func disconnect() async {
        invalidateTransport()
        cleanupLibssh2()

        logger.info("Disconnected")
    }

    func invalidateTransport() {
        isActive = false
        connectedPeerAddress = nil
        abandonAllShellChannels()
        ioTask?.cancel()
        ioTask = nil
        failAllExecRequests(error: SSHError.notConnected)
        atomicSocket.interrupt()
        socket = -1
    }

    func cleanupLibssh2() {
        // A startup operation may still own a channel pointer across an actor
        // suspension. Its defer releases that ownership before final cleanup.
        guard shellStartupsInFlight.isEmpty else { return }
        // Prevent double cleanup
        guard !hasBeenCleaned else { return }
        sftpSession = nil

        guard let session = libssh2Session else {
            hasBeenCleaned = true
            atomicSocket.close()
            return
        }

        var freeResult = Int32(LIBSSH2_ERROR_EAGAIN)
        for _ in 0..<1_024 {
            freeResult = libssh2_session_free(session)
            if freeResult != LIBSSH2_ERROR_EAGAIN {
                break
            }
        }
        if freeResult == 0 {
            libssh2Session = nil
            hasBeenCleaned = true
            atomicSocket.close()
        } else {
            // No Swift operation may call the native session at this point. If
            // libssh2 still cannot finish, abandon its allocation rather than
            // calling into a partial operation or leaking the descriptor.
            logger.error("Abandoning incomplete libssh2 session cleanup: \(freeResult)")
            libssh2Session = nil
            hasBeenCleaned = true
            atomicSocket.close()
        }
    }

    func cleanup() {
        // Close socket first to abort any blocking I/O
        atomicSocket.interrupt()
        socket = -1
        connectedPeerAddress = nil
        cleanupLibssh2()
    }

    func remoteEndpointHost() -> String? {
        connectedPeerAddress
    }

    func startIOLoop() {
        guard ioTask == nil else { return }
        ioTask = Task { [weak self] in
            await self?.ioLoop()
        }
    }

    private func stopIOLoop() {
        ioTask?.cancel()
        ioTask = nil
    }

    private func ioLoop() async {
        var buffer = [CChar](repeating: 0, count: 32768)
        let batchThreshold = 65536  // 64KB batch threshold

        // Adaptive batch delay: track data rate to switch between interactive and bulk modes
        // Interactive mode (keystrokes): 1ms delay for minimum latency
        // Bulk mode (command output): 5ms delay for better throughput
        let interactiveDelay: UInt64 = 1_000_000   // 1ms
        let bulkDelay: UInt64 = 5_000_000          // 5ms
        let interactiveThreshold = 100             // bytes - below this is interactive
        let bulkThreshold = 1000                   // bytes - above this is bulk

        while !Task.isCancelled, libssh2Session != nil {
            var didWork = false

            if !shellChannels.isEmpty {
                let states = Array(shellChannels.values)
                for state in states {
                    // Use _ex variant since macros not available in Swift (stream_id 0 = stdout)
                    let bytesRead = libssh2_channel_read_ex(state.channel, 0, &buffer, buffer.count)

                    if bytesRead > 0 {
                        if !state.didRecordFirstByte {
                            state.didRecordFirstByte = true
                            startupTrace?.recordOnce(.firstTerminalByte, detail: "ssh")
                        }
                        let readCount = Int(bytesRead)
                        state.batchBuffer.append(Data(bytes: buffer, count: readCount))
                        didWork = true

                        // Update exponential moving average (alpha = 0.3 for quick adaptation)
                        state.recentBytesPerRead = (state.recentBytesPerRead * 7 + readCount * 3) / 10

                        // Adaptive delay based on data rate
                        let maxBatchDelay: UInt64
                        if state.recentBytesPerRead < interactiveThreshold {
                            maxBatchDelay = interactiveDelay  // Fast for keystrokes
                        } else if state.recentBytesPerRead > bulkThreshold {
                            maxBatchDelay = bulkDelay         // Slower for bulk data
                        } else {
                            // Linear interpolation between modes
                            let ratio = UInt64(state.recentBytesPerRead - interactiveThreshold) * 100 / UInt64(bulkThreshold - interactiveThreshold)
                            maxBatchDelay = interactiveDelay + (bulkDelay - interactiveDelay) * ratio / 100
                        }

                        // Yield batch when threshold reached or enough time passed
                        let now = DispatchTime.now().uptimeNanoseconds
                        let timeSinceYield = now - state.lastYieldTime

                        if state.batchBuffer.count >= batchThreshold || timeSinceYield >= maxBatchDelay {
                            guard await flushShellOutput(state) else {
                                await closeShellInternal(state.id)
                                continue
                            }
                            state.lastYieldTime = now
                        }
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // Flush any pending data before waiting
                        if !state.batchBuffer.isEmpty,
                           !(await flushShellOutput(state)) {
                            await closeShellInternal(state.id)
                            continue
                        }
                        if shellChannels[state.id] != nil {
                            state.lastYieldTime = DispatchTime.now().uptimeNanoseconds
                        }
                        // Reset to interactive mode when idle (waiting for input)
                        state.recentBytesPerRead = 0
                    } else if bytesRead < 0 {
                        // Error - flush remaining data first
                        let preservesOutput = await flushShellOutput(state)
                        logger.error("Read error: \(bytesRead)")
                        await closeShellInternal(
                            state.id,
                            preservesOutput: preservesOutput
                        )
                        continue
                    }

                    // Check for EOF
                    if libssh2_channel_eof(state.channel) != 0 {
                        let preservesOutput = await flushShellOutput(state)
                        logger.info("Channel EOF")
                        await closeShellInternal(
                            state.id,
                            preservesOutput: preservesOutput
                        )
                        didWork = true
                    }
                }
            }

            if !execRequests.isEmpty {
                let requestIds = Array(execRequests.keys)
                for requestId in requestIds {
                    guard let request = execRequests[requestId] else { continue }
                    guard await ensureExecChannelReady(request) else { continue }

                    guard let execChannel = request.channel else { continue }

                    let bytesRead = libssh2_channel_read_ex(execChannel, 0, &buffer, buffer.count)
                    if bytesRead > 0 {
                        let readCount = Int(bytesRead)
                        guard request.outputBudget.reserve(readCount) else {
                            await finishExecRequest(requestId, error: SSHError.outputLimitExceeded)
                            continue
                        }
                        request.output.append(Data(bytes: buffer, count: readCount))
                        didWork = true
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No data yet
                    } else if bytesRead < 0 {
                        await finishExecRequest(requestId, error: SSHError.socketError("Exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = libssh2_channel_read_ex(execChannel, 1, &buffer, buffer.count)
                    if stderrRead > 0 {
                        let readCount = Int(stderrRead)
                        guard request.outputBudget.reserve(readCount) else {
                            await finishExecRequest(requestId, error: SSHError.outputLimitExceeded)
                            continue
                        }
                        request.stderr.append(Data(bytes: buffer, count: readCount))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet
                    } else if stderrRead < 0 {
                        await finishExecRequest(requestId, error: SSHError.socketError("Exec stderr read failed: \(stderrRead)"))
                        continue
                    }

                    if let currentChannel = request.channel, libssh2_channel_eof(currentChannel) != 0 {
                        await finishExecRequest(requestId, error: nil)
                        didWork = true
                    }
                }
            }

            if shellChannels.isEmpty, execRequests.isEmpty {
                break
            }

            if !didWork {
                await waitForSocket()
            }

            // Always yield to prevent starving other tasks (especially important during rapid typing)
            // This ensures write operations and UI updates get CPU time
            await Task.yield()
        }

        await closeAllShellChannels()
        stopIOLoop()
    }

    func waitForSocket() async {
        guard let session = libssh2Session, socket >= 0 else { return }

        let direction = libssh2_session_block_directions(session)
        guard direction != 0 else { return }

        var events: Int16 = 0

        if direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            events |= Int16(POLLIN)
        }
        if direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            events |= Int16(POLLOUT)
        }

        await SSHSocketReadinessPoller.shared.wait(
            fileDescriptor: socket,
            events: events,
            timeoutMilliseconds: 5
        )
    }

    func resolveNumericPeerAddress(for socket: Int32) -> String? {
        var storage = sockaddr_storage()
        var storageLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let peerResult = withUnsafeMutablePointer(to: &storage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getpeername(socket, sockaddrPtr, &storageLen)
            }
        }
        guard peerResult == 0 else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let nameResult = withUnsafePointer(to: &storage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getnameinfo(
                    sockaddrPtr,
                    storageLen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard nameResult == 0 else { return nil }
        return String(cString: hostBuffer)
    }

    // MARK: - Keep Alive

    func sendKeepAlive() {
        guard let session = libssh2Session else { return }
        var secondsToNext: Int32 = 0
        libssh2_keepalive_send(session, &secondsToNext)
    }

}

// MARK: - fd_set helpers for select()

private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    guard fd >= 0, fd < FD_SETSIZE else { return }
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutableBytes(of: &set.fds_bits) { buf in
        guard let baseAddress = buf.baseAddress,
              intOffset * MemoryLayout<Int32>.size < buf.count else { return }
        let ptr = baseAddress.assumingMemoryBound(to: Int32.self)
        ptr[intOffset] |= Int32(1 << bitOffset)
    }
}
