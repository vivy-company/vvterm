import Foundation
import os.log

// MARK: - SSH Client using libssh2

actor SSHClient {
    private var session: SSHSession?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSH")
    private var keepAliveTask: Task<Void, Never>?

    /// Stored session reference for nonisolated abort access
    private nonisolated(unsafe) var _sessionForAbort: SSHSession?

    /// Flag to track if abort was called - prevents new operations
    private nonisolated(unsafe) var _isAborted = false

    /// Immediately abort the connection by closing the socket (non-blocking, can be called from any thread)
    nonisolated func abort() {
        _isAborted = true
        _sessionForAbort?.abort()
    }

    /// Check if the client has been aborted
    var isAborted: Bool {
        _isAborted
    }

    // MARK: - Connection

    func connect(to server: Server, credentials: ServerCredentials) async throws -> SSHSession {
        logger.info("Connecting to \(server.host):\(server.port)")
        logger.info("Auth method: \(String(describing: server.authMethod)), password present: \(credentials.password != nil)")

        let config = SSHSessionConfig(
            host: server.host,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            credentials: credentials
        )

        let session = SSHSession(config: config)
        try await session.connect()

        self.session = session
        self._sessionForAbort = session
        startKeepAlive()

        logger.info("Connected to \(server.host)")
        return session
    }

    func disconnect() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil

        await session?.disconnect()
        session = nil
        _sessionForAbort = nil

        logger.info("Disconnected")
    }

    // MARK: - Command Execution

    func execute(_ command: String) async throws -> String {
        guard !_isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }
        return try await session.execute(command)
    }

    // MARK: - Shell

    func startShell(cols: Int = 80, rows: Int = 24) async throws -> AsyncStream<Data> {
        guard let session = session else {
            throw SSHError.notConnected
        }
        return try await session.startShell(cols: cols, rows: rows)
    }

    func write(_ data: Data) async throws {
        guard !_isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.write(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.resize(cols: cols, rows: rows)
    }

    // MARK: - Keep Alive

    private func startKeepAlive(interval: TimeInterval = 30) {
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await session?.sendKeepAlive()
            }
        }
    }

    // MARK: - State

    var isConnected: Bool {
        get async {
            await session?.isConnected ?? false
        }
    }
}

// MARK: - Keyboard Interactive Auth Helper

// Global storage for keyboard-interactive password (needed for C callback)
private var kbdintPassword: String?

// C callback for keyboard-interactive authentication
private let kbdintCallback: @convention(c) (
    UnsafePointer<CChar>?,  // name
    Int32,                   // name_len
    UnsafePointer<CChar>?,  // instruction
    Int32,                   // instruction_len
    Int32,                   // num_prompts
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,  // prompts
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,  // responses
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?  // abstract
) -> Void = { name, nameLen, instruction, instructionLen, numPrompts, prompts, responses, abstract in
    guard numPrompts > 0, let responses = responses, let password = kbdintPassword else {
        return
    }

    // For each prompt, provide the password
    for i in 0..<Int(numPrompts) {
        let passwordData = password.utf8CString
        let length = passwordData.count - 1  // exclude null terminator

        // Allocate memory for response (libssh2 will free it)
        let responseBuf = UnsafeMutablePointer<CChar>.allocate(capacity: length)
        passwordData.withUnsafeBufferPointer { buffer in
            responseBuf.initialize(from: buffer.baseAddress!, count: length)
        }

        responses[i].text = responseBuf
        responses[i].length = UInt32(length)
    }
}

// MARK: - SSH Session using libssh2

actor SSHSession {
    let config: SSHSessionConfig
    private var libssh2Session: OpaquePointer?
    private var channel: OpaquePointer?
    private var socket: Int32 = -1
    private var isActive = false
    private var shellContinuation: AsyncStream<Data>.Continuation?
    private var readTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "SSHSession")

    /// Atomic socket storage for emergency abort from any thread
    private let atomicSocket = AtomicSocket()

    init(config: SSHSessionConfig) {
        self.config = config
    }

    var isConnected: Bool {
        isActive && libssh2Session != nil
    }

    /// Immediately abort the connection by closing the socket (can be called from any thread)
    nonisolated func abort() {
        atomicSocket.closeImmediately()
    }

    // MARK: - Connection

    func connect() async throws {
        // Initialize libssh2
        let rc = libssh2_init(0)
        guard rc == 0 else {
            throw SSHError.unknown("libssh2_init failed: \(rc)")
        }

        // Create socket
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw SSHError.socketError("Failed to create socket")
        }

        // Resolve host
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?

        let portString = String(config.port)
        let resolveResult = getaddrinfo(config.host, portString, &hints, &result)
        guard resolveResult == 0, let addrInfo = result else {
            Darwin.close(socket)
            throw SSHError.connectionFailed("Failed to resolve host: \(config.host)")
        }
        defer { freeaddrinfo(result) }

        // Connect socket
        let connectResult = Darwin.connect(socket, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)
        guard connectResult == 0 else {
            Darwin.close(socket)
            throw SSHError.connectionFailed("Failed to connect: \(String(cString: strerror(errno)))")
        }

        // Store in atomic storage for emergency abort
        atomicSocket.socket = socket

        // Create libssh2 session (use _ex variant since macros not available in Swift)
        libssh2Session = libssh2_session_init_ex(nil, nil, nil, nil)
        guard let session = libssh2Session else {
            Darwin.close(socket)
            throw SSHError.unknown("Failed to create libssh2 session")
        }

        // Set blocking mode for handshake
        libssh2_session_set_blocking(session, 1)

        // Perform SSH handshake
        let handshakeResult = libssh2_session_handshake(session, socket)
        guard handshakeResult == 0 else {
            cleanup()
            throw SSHError.connectionFailed("SSH handshake failed: \(handshakeResult)")
        }

        // Authenticate
        try authenticate()

        // Set non-blocking for I/O
        libssh2_session_set_blocking(session, 0)

        isActive = true
        logger.info("SSH session established")
    }

    private func authenticate() throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        let username = config.username
        var authResult: Int32 = -1

        // Query supported auth methods
        let authList = libssh2_userauth_list(session, username, UInt32(username.utf8.count))
        if let authListPtr = authList {
            let methods = String(cString: authListPtr)
            logger.info("Server auth methods: \(methods)")
        } else {
            // If authList is nil, check if already authenticated
            if libssh2_userauth_authenticated(session) != 0 {
                logger.info("Already authenticated")
                return
            }
            logger.warning("Could not get auth methods list")
        }

        switch config.authMethod {
        case .password:
            guard let password = config.credentials.password else {
                logger.error("No password provided")
                throw SSHError.authenticationFailed
            }
            logger.info("Attempting password auth for user: \(username)")

            // Use _ex variant since macros not available in Swift
            authResult = libssh2_userauth_password_ex(
                session,
                username,
                UInt32(username.utf8.count),
                password,
                UInt32(password.utf8.count),
                nil
            )

            // If password auth fails, try keyboard-interactive as fallback
            if authResult != 0 {
                logger.info("Password auth failed, trying keyboard-interactive...")

                // Store password for the callback
                kbdintPassword = password
                defer { kbdintPassword = nil }

                authResult = libssh2_userauth_keyboard_interactive_ex(
                    session,
                    username,
                    UInt32(username.utf8.count),
                    kbdintCallback
                )
            }

        case .sshKey, .sshKeyWithPassphrase:
            guard let keyData = config.credentials.privateKey else {
                logger.error("No private key provided")
                throw SSHError.authenticationFailed
            }
            let passphrase = config.credentials.passphrase

            // Write key to temp file (libssh2 requires file path)
            let tempKeyPath = NSTemporaryDirectory() + UUID().uuidString + ".key"
            try keyData.write(to: URL(fileURLWithPath: tempKeyPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempKeyPath)
            defer { try? FileManager.default.removeItem(atPath: tempKeyPath) }

            logger.info("Attempting publickey auth for user: \(username)")

            // Use _ex variant since macros not available in Swift
            authResult = libssh2_userauth_publickey_fromfile_ex(
                session,
                username,
                UInt32(username.utf8.count),
                nil, // public key (auto-derived)
                tempKeyPath,
                passphrase
            )
        }

        if authResult != 0 {
            // Get detailed error message
            var errmsg: UnsafeMutablePointer<CChar>?
            var errmsg_len: Int32 = 0
            libssh2_session_last_error(session, &errmsg, &errmsg_len, 0)
            let errorMsg = errmsg != nil ? String(cString: errmsg!) : "Unknown error"
            logger.error("Auth failed (\(authResult)): \(errorMsg)")
            throw SSHError.authenticationFailed
        }

        logger.info("Authentication successful")
    }

    func disconnect() async {
        // Mark as inactive first to stop any pending operations
        isActive = false

        // Finish the stream continuation first to unblock any waiting consumers
        shellContinuation?.finish()
        shellContinuation = nil

        // Cancel read task
        readTask?.cancel()
        readTask = nil

        // Close socket first to abort any blocking I/O in libssh2
        atomicSocket.closeImmediately()
        socket = -1

        // Now cleanup libssh2 resources (won't block since socket is closed)
        cleanupLibssh2()

        logger.info("Disconnected")
    }

    private func cleanupLibssh2() {
        if let channel = channel {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
            self.channel = nil
        }
        if let session = libssh2Session {
            libssh2_session_disconnect_ex(session, 11, "Normal shutdown", "")
            libssh2_session_free(session)
            libssh2Session = nil
        }
        libssh2_exit()
    }

    private func cleanup() {
        // Close socket first to abort any blocking I/O
        atomicSocket.closeImmediately()
        socket = -1
        cleanupLibssh2()
    }

    // MARK: - Shell

    func startShell(cols: Int, rows: Int) async throws -> AsyncStream<Data> {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        // Set blocking for channel setup
        libssh2_session_set_blocking(session, 1)

        // Open channel (use _ex variant since macros not available in Swift)
        // LIBSSH2_CHANNEL_WINDOW_DEFAULT = 2*1024*1024, LIBSSH2_CHANNEL_PACKET_DEFAULT = 32768
        channel = libssh2_channel_open_ex(
            session,
            "session",
            UInt32("session".utf8.count),
            2 * 1024 * 1024,  // window size
            32768,             // packet size
            nil,
            0
        )
        guard let channel = channel else {
            throw SSHError.channelOpenFailed
        }

        // Request PTY
        let ptyResult = libssh2_channel_request_pty_ex(
            channel,
            "xterm-256color",
            UInt32("xterm-256color".count),
            nil,
            0,
            Int32(cols),
            Int32(rows),
            0,
            0
        )
        guard ptyResult == 0 else {
            throw SSHError.shellRequestFailed
        }

        // Start shell (use process_startup since shell macro not available in Swift)
        let shellResult = libssh2_channel_process_startup(channel, "shell", 5, nil, 0)
        guard shellResult == 0 else {
            throw SSHError.shellRequestFailed
        }

        // Set non-blocking for I/O
        libssh2_session_set_blocking(session, 0)

        logger.info("Shell started (\(cols)x\(rows))")

        // Create output stream
        let stream = AsyncStream<Data> { continuation in
            self.shellContinuation = continuation

            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.stopReading()
                }
            }
        }

        // Start reading in background
        startReading()

        return stream
    }

    private func startReading() {
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func stopReading() {
        readTask?.cancel()
        readTask = nil
    }

    private func readLoop() async {
        var buffer = [CChar](repeating: 0, count: 32768)

        while !Task.isCancelled, let channel = channel, let session = libssh2Session {
            // Use _ex variant since macros not available in Swift (stream_id 0 = stdout)
            let bytesRead = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: Int(bytesRead))
                shellContinuation?.yield(data)
            } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                // Would block, wait and retry
                await waitForSocket()
            } else if bytesRead < 0 {
                // Error
                logger.error("Read error: \(bytesRead)")
                break
            }

            // Check for EOF
            if libssh2_channel_eof(channel) != 0 {
                logger.info("Channel EOF")
                break
            }

            // Small yield to prevent tight loop
            try? await Task.sleep(for: .milliseconds(1))
        }

        shellContinuation?.finish()
    }

    private func waitForSocket() async {
        guard let session = libssh2Session else { return }

        let direction = libssh2_session_block_directions(session)

        var readfds = fd_set()
        var writefds = fd_set()
        fdZero(&readfds)
        fdZero(&writefds)

        if direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            fdSet(socket, &readfds)
        }
        if direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            fdSet(socket, &writefds)
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 10000) // 10ms
        _ = select(socket + 1, &readfds, &writefds, nil, &timeout)
    }

    // MARK: - Write

    func write(_ data: Data) async throws {
        guard let channel = channel else {
            throw SSHError.notConnected
        }

        try data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return
            }

            var remaining = data.count
            var offset = 0

            while remaining > 0 {
                // Use _ex variant since macros not available in Swift (stream_id 0 = stdin)
                let written = libssh2_channel_write_ex(channel, 0, ptr.advanced(by: offset), remaining)

                if written > 0 {
                    offset += Int(written)
                    remaining -= Int(written)
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    // Would block, wait
                    Task { await waitForSocket() }
                    continue
                } else {
                    throw SSHError.socketError("Write failed: \(written)")
                }
            }
        }
    }

    // MARK: - Resize

    func resize(cols: Int, rows: Int) async throws {
        guard let channel = channel else {
            throw SSHError.notConnected
        }

        // Use _ex variant since macros not available in Swift
        let result = libssh2_channel_request_pty_size_ex(channel, Int32(cols), Int32(rows), 0, 0)
        if result != 0 && result != Int32(LIBSSH2_ERROR_EAGAIN) {
            logger.warning("PTY resize failed: \(result)")
        }
    }

    // MARK: - Execute Command

    func execute(_ command: String) async throws -> String {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        // Set blocking for exec
        libssh2_session_set_blocking(session, 1)
        defer { libssh2_session_set_blocking(session, 0) }

        // Open exec channel (use _ex variant since macros not available in Swift)
        guard let execChannel = libssh2_channel_open_ex(
            session,
            "session",
            UInt32("session".utf8.count),
            2 * 1024 * 1024,
            32768,
            nil,
            0
        ) else {
            throw SSHError.channelOpenFailed
        }
        defer {
            libssh2_channel_close(execChannel)
            libssh2_channel_free(execChannel)
        }

        // Execute command (use process_startup since exec macro not available in Swift)
        let execResult = libssh2_channel_process_startup(
            execChannel,
            "exec",
            4,
            command,
            UInt32(command.utf8.count)
        )
        guard execResult == 0 else {
            throw SSHError.unknown("Exec failed: \(execResult)")
        }

        // Read output
        var output = Data()
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            // Use _ex variant since macros not available in Swift (stream_id 0 = stdout)
            let bytesRead = libssh2_channel_read_ex(execChannel, 0, &buffer, buffer.count)
            if bytesRead > 0 {
                output.append(Data(bytes: buffer, count: Int(bytesRead)))
            } else {
                break
            }
        }

        return String(data: output, encoding: .utf8) ?? ""
    }

    // MARK: - Keep Alive

    func sendKeepAlive() {
        guard let session = libssh2Session else { return }
        var secondsToNext: Int32 = 0
        libssh2_keepalive_send(session, &secondsToNext)
    }
}

// MARK: - SSH Session Config

struct SSHSessionConfig {
    let host: String
    let port: Int
    let username: String
    let authMethod: AuthMethod
    let credentials: ServerCredentials

    var connectionTimeout: TimeInterval = 30
    var keepAliveInterval: TimeInterval = 30
}

// MARK: - SSH Error

enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case timeout
    case channelOpenFailed
    case shellRequestFailed
    case hostKeyVerificationFailed
    case socketError(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .timeout: return "Connection timed out"
        case .channelOpenFailed: return "Failed to open channel"
        case .shellRequestFailed: return "Failed to request shell"
        case .hostKeyVerificationFailed: return "Host key verification failed"
        case .socketError(let msg): return "Socket error: \(msg)"
        case .unknown(let msg): return "Unknown error: \(msg)"
        }
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

// MARK: - Atomic Socket for Thread-Safe Abort

/// Thread-safe socket storage that allows closing from any thread
final class AtomicSocket: @unchecked Sendable {
    private var _socket: Int32 = -1
    private let lock = NSLock()

    var socket: Int32 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _socket
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _socket = newValue
        }
    }

    /// Close the socket immediately from any thread
    func closeImmediately() {
        lock.lock()
        let sock = _socket
        _socket = -1
        lock.unlock()

        if sock >= 0 {
            Darwin.close(sock)
        }
    }
}
