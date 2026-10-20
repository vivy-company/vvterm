import Foundation
import Darwin
import os.log

// MARK: - Keyboard Interactive Auth Helper

/// Per-session storage for keyboard-interactive password (used by C callback).
/// This avoids cross-session password races when multiple auth flows run concurrently.
final class KeyboardInteractiveContext: @unchecked Sendable {
    private nonisolated(unsafe) var _password: String?
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func setPassword(_ password: String?) {
        lock.lock()
        defer { lock.unlock() }
        _password = password
    }

    nonisolated func password() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _password
    }
}

nonisolated private func keyboardInteractivePassword(
    from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> String? {
    guard let abstract, let contextPointer = abstract.pointee else { return nil }
    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPointer).takeUnretainedValue()
    return context.password()
}

// C callback for keyboard-interactive authentication
nonisolated private func kbdintCallback(
    _ name: UnsafePointer<CChar>?,
    _ nameLen: Int32,
    _ instruction: UnsafePointer<CChar>?,
    _ instructionLen: Int32,
    _ numPrompts: Int32,
    _ prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    _ responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) {
    guard numPrompts > 0, let responses = responses, let password = keyboardInteractivePassword(from: abstract) else {
        return
    }

    // For each prompt, provide the password
    for i in 0..<Int(numPrompts) {
        let passwordData = password.utf8CString
        let length = passwordData.count - 1  // exclude null terminator

        // Allocate memory for response (libssh2 will free it)
        let responseBuf = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        passwordData.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            responseBuf.initialize(from: baseAddress, count: length)
        }
        responseBuf[length] = 0

        responses[i].text = responseBuf
        responses[i].length = UInt32(length)
    }
}

extension SSHSession {
    // MARK: - Connection

    func connect() async throws {
        try Task.checkCancellation()
        guard !hasBeenCleaned, !connectionStartupInFlight, libssh2Session == nil else {
            throw SSHError.notConnected
        }
        guard config.connectionMode != .teleport || preparedConnection != nil else {
            throw SSHError.connectionFailed("Teleport requires a prepared SSH stream")
        }
        try LibSSH2Runtime.ensureInitialized()
        connectionStartupInFlight = true
        defer {
            connectionStartupInFlight = false
            if !isActive { cleanup() }
        }
        socket = -1
        connectedPeerAddress = nil

        if let preparedConnection {
            socket = try preparedConnection.takeSocketDescriptor()
            guard socket >= 0 else {
                throw SSHError.connectionFailed("The prepared SSH stream has no socket")
            }
            atomicSocket.install(socket)
            let flags = fcntl(socket, F_GETFL)
            guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw SSHError.connectionFailed("Cannot configure the prepared SSH stream")
            }
        } else {
            socket = try await SSHAddressConnector.connect(
                host: config.dialHost,
                port: config.dialPort,
                trace: startupTrace
            )
            atomicSocket.install(socket)
            connectedPeerAddress = resolveNumericPeerAddress(for: socket)

            // TCP tuning does not apply to provider-owned Unix socket streams.
            var noDelay: Int32 = 1
            setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            var sendBufSize: Int32 = 8192
            var recvBufSize: Int32 = 65536
            setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &sendBufSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &recvBufSize, socklen_t(MemoryLayout<Int32>.size))
        }

        // Prevent SIGPIPE on broken connections (handle errors in code instead)
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Create libssh2 session (use _ex variant since macros not available in Swift)
        let sessionAbstract = Unmanaged.passUnretained(keyboardInteractiveContext).toOpaque()
        libssh2Session = libssh2_session_init_ex(nil, nil, nil, sessionAbstract)
        guard let session = libssh2Session else {
            atomicSocket.close()
            self.socket = -1
            throw SSHError.unknown("Failed to create libssh2 session")
        }

        // Prefer fast ciphers - AES-GCM and ChaCha20 are hardware-accelerated on Apple Silicon
        // This reduces CPU overhead for encryption/decryption
        let fastCiphers = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr,aes256-ctr"
        libssh2_session_method_pref(session, LIBSSH2_METHOD_CRYPT_CS, fastCiphers)
        libssh2_session_method_pref(session, LIBSSH2_METHOD_CRYPT_SC, fastCiphers)

        // Prefer fast MACs (message authentication codes)
        let fastMACs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"
        libssh2_session_method_pref(session, LIBSSH2_METHOD_MAC_CS, fastMACs)
        libssh2_session_method_pref(session, LIBSSH2_METHOD_MAC_SC, fastMACs)

        let isPrepared = preparedConnection != nil
        libssh2_session_set_blocking(session, isPrepared ? 0 : 1)
        try configureHostKeyMethods(session: session, requiresCertificate: isPrepared)

        // Perform SSH handshake
        try Task.checkCancellation()
        let handshakeToken = startupTrace?.begin(.sshHandshake)
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(config.connectionTimeout))
        let handshakeResult: Int32
        if isPrepared {
            handshakeResult = try await completePreparedStartupCall(
                session: session,
                deadline: startupDeadline
            ) {
                libssh2_session_handshake(session, socket)
            }
        } else {
            handshakeResult = libssh2_session_handshake(session, socket)
        }
        guard handshakeResult == 0 else {
            if let handshakeToken { startupTrace?.end(handshakeToken, outcome: "failed") }
            cleanup()
            throw SSHError.connectionFailed("SSH handshake failed: \(handshakeResult)")
        }
        if let handshakeToken { startupTrace?.end(handshakeToken) }

        let hostKeyToken = startupTrace?.begin(.hostKeyVerification)
        do {
            try verifyHostKey()
            if let hostKeyToken { startupTrace?.end(hostKeyToken) }
        } catch {
            if let hostKeyToken { startupTrace?.end(hostKeyToken, outcome: "failed") }
            cleanup()
            throw error
        }

        // Authenticate
        try Task.checkCancellation()
        let authenticationToken = startupTrace?.begin(.authentication)
        do {
            if let preparedConnection {
                try await authenticatePreparedConnection(
                    preparedConnection,
                    session: session,
                    deadline: startupDeadline
                )
            } else {
                try authenticate()
            }
            if let authenticationToken { startupTrace?.end(authenticationToken) }
        } catch {
            if let authenticationToken { startupTrace?.end(authenticationToken, outcome: "failed") }
            throw error
        }

        // Set non-blocking for I/O
        libssh2_session_set_blocking(session, 0)

        isActive = true
        logger.info("SSH session established")
    }

    private func configureHostKeyMethods(session: OpaquePointer, requiresCertificate: Bool) throws {
        var algorithms: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        let count = libssh2_session_supported_algs(session, LIBSSH2_METHOD_HOSTKEY, &algorithms)
        defer { if let algorithms { libssh2_free(session, algorithms) } }
        guard count > 0, let algorithms else {
            throw SSHError.hostKeyVerificationFailed
        }
        let supported = (0..<Int(count)).compactMap { index in
            algorithms[index].map { String(cString: $0) }
        }
        guard let preference = Self.hostKeyMethodPreference(
            supported: supported,
            requiresCertificate: requiresCertificate
        ), libssh2_session_method_pref(session, LIBSSH2_METHOD_HOSTKEY, preference) == 0 else {
            throw SSHError.hostKeyVerificationFailed
        }
    }

    /// A saved-host session must not store a certificate fingerprint as a
    /// permanent host key, and a provider must never fall back to a raw key.
    nonisolated static func hostKeyMethodPreference(
        supported: [String],
        requiresCertificate: Bool
    ) -> String? {
        let selected = supported.filter { method in
            requiresCertificate
                ? method.hasSuffix("-cert-v01@openssh.com")
                    && method != "ssh-rsa-cert-v01@openssh.com"
                    && method != "ssh-dss-cert-v01@openssh.com"
                : !method.contains("-cert-")
        }
        guard !selected.isEmpty else { return nil }
        if requiresCertificate { return selected.joined(separator: ",") }

        // Keep prior direct host-key selection across the engine update so
        // existing multi-key servers do not acquire a different fingerprint.
        let previousOrder = [
            "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
            "ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa",
        ]
        let ordered = previousOrder.filter { selected.contains($0) }
            + selected.filter { !previousOrder.contains($0) }
        return ordered.joined(separator: ",")
    }

    private func completePreparedStartupCall(
        session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        call: () -> Int32
    ) async throws -> Int32 {
        while true {
            try Task.checkCancellation()
            guard atomicSocket.isUsable, libssh2Session == session else {
                throw SSHError.notConnected
            }
            guard ContinuousClock.now < deadline else { throw SSHError.timeout }
            let result = call()
            guard result == LIBSSH2_ERROR_EAGAIN else { return result }
            if libssh2_session_block_directions(session) == 0 {
                // A provider implementation can return EAGAIN without a socket
                // direction. Still suspend and preserve cancellation/deadlines.
                try await Task.sleep(for: .milliseconds(1))
            } else {
                await waitForSocket()
            }
        }
    }

    private func authenticatePreparedConnection(
        _ connection: any SSHPreparedConnection,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant
    ) async throws {
        let certificate = connection.sshCertificate
        let privateKey = connection.sshPrivateKey
        guard !certificate.isEmpty, !privateKey.isEmpty else {
            throw SSHError.authenticationFailed
        }
        let result = try await completePreparedStartupCall(session: session, deadline: deadline) {
            certificate.withUnsafeBytes { certificateBytes in
                privateKey.withUnsafeBytes { keyBytes in
                    libssh2_userauth_publickey_frommemory(
                        session,
                        config.username,
                        config.username.utf8.count,
                        certificateBytes.bindMemory(to: CChar.self).baseAddress,
                        certificate.count,
                        keyBytes.bindMemory(to: CChar.self).baseAddress,
                        privateKey.count,
                        nil
                    )
                }
            }
        }
        guard result == 0 else { throw SSHError.authenticationFailed }
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
            logger.info("Server auth methods [mode: \(self.config.connectionMode.rawValue)]: \(methods)")
        } else {
            logger.warning("Could not get auth methods list")
        }

        if config.connectionMode == .tailscale {
            if libssh2_userauth_authenticated(session) != 0 {
                logger.info("Tailscale SSH authentication accepted by server policy")
                return
            }
            logger.error("Tailscale SSH auth not accepted by server")
            throw SSHError.tailscaleAuthenticationNotAccepted
        }

        // If authList is nil, check if already authenticated
        if authList == nil, libssh2_userauth_authenticated(session) != 0 {
            logger.info("Already authenticated")
            return
        }

        guard let authMethod = config.authMethod else { throw SSHError.authenticationFailed }
        switch authMethod {
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

                keyboardInteractiveContext.setPassword(password)
                defer { keyboardInteractiveContext.setPassword(nil) }

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
            let publicKeyData = config.credentials.publicKey
            logger.info("Attempting publickey auth for user: \(username)")

            authResult = keyData.withUnsafeBytes { rawBuffer -> Int32 in
                guard let baseAddress = rawBuffer.bindMemory(to: CChar.self).baseAddress else {
                    return LIBSSH2_ERROR_ALLOC
                }

                if let publicKeyData, !publicKeyData.isEmpty {
                    return publicKeyData.withUnsafeBytes { publicBuffer -> Int32 in
                        guard let publicBase = publicBuffer.bindMemory(to: CChar.self).baseAddress else {
                            return LIBSSH2_ERROR_ALLOC
                        }
                        return libssh2_userauth_publickey_frommemory(
                            session,
                            username,
                            Int(username.utf8.count),
                            publicBase,
                            Int(publicKeyData.count),
                            baseAddress,
                            Int(keyData.count),
                            passphrase
                        )
                    }
                }

                return libssh2_userauth_publickey_frommemory(
                    session,
                    username,
                    Int(username.utf8.count),
                    nil,
                    0,
                    baseAddress,
                    Int(keyData.count),
                    passphrase
                )
            }
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

    private func verifyHostKey() throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        if let preparedConnection {
            var length: size_t = 0
            var type: Int32 = 0
            guard let bytes = libssh2_session_hostkey(session, &length, &type),
                  length > 0,
                  length <= 262_144 else {
                throw SSHError.hostKeyVerificationFailed
            }
            try preparedConnection.verifyHostCertificate(Data(bytes: bytes, count: length))
            return
        }

        let (fingerprint, keyType) = try hostKeyFingerprint(for: session)
        let host = config.hostKeyHost
        let port = config.hostKeyPort

        let result = hostKeyVerifier.verify(SSHHostKeyCandidate(
            host: host,
            port: port,
            fingerprint: fingerprint,
            keyType: keyType,
            keyTypeName: hostKeyTypeName(keyType)
        ))
        switch result {
        case .trusted:
            logger.info("Host key verified for \(host, privacy: .private(mask: .hash)):\(port)")
        case .approvalRequired:
            logger.notice(
                "SSH host key needs user approval for \(host, privacy: .private(mask: .hash)):\(port)"
            )
            throw SSHError.hostKeyApprovalRequired
        }
    }

    private func hostKeyFingerprint(for session: OpaquePointer) throws -> (String, Int) {
        guard let hashPtr = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw SSHError.hostKeyVerificationFailed
        }

        let hash = Data(bytes: hashPtr, count: 32)
        let base64 = hash.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fingerprint = "SHA256:\(base64)"

        var keyLen: size_t = 0
        var keyType: Int32 = 0
        _ = libssh2_session_hostkey(session, &keyLen, &keyType)

        return (fingerprint, Int(keyType))
    }

    private func hostKeyTypeName(_ keyType: Int) -> String {
        switch keyType {
        case Int(LIBSSH2_HOSTKEY_TYPE_RSA):
            return "RSA"
        case Int(LIBSSH2_HOSTKEY_TYPE_DSS):
            return "DSA"
        case Int(LIBSSH2_HOSTKEY_TYPE_ECDSA_256):
            return "ECDSA P-256"
        case Int(LIBSSH2_HOSTKEY_TYPE_ECDSA_384):
            return "ECDSA P-384"
        case Int(LIBSSH2_HOSTKEY_TYPE_ECDSA_521):
            return "ECDSA P-521"
        case Int(LIBSSH2_HOSTKEY_TYPE_ED25519):
            return "ED25519"
        default:
            return String(localized: "Unknown")
        }
    }
}
