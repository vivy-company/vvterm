#if os(macOS)
import CryptoKit
import Foundation
import TeleportKit
import Testing
@testable import VVTerm

/// Uses the package's disposable lab manifest. No Keychain or system trust is changed.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VVTERM_TELEPORT_FIXTURE"] != nil))
struct TeleportSessionFlowIntegrationTests {
    private struct Fixture: Decodable {
        struct Node: Decodable { let id: String; let authorized: Bool }
        let schemaVersion: Int
        let proxyURL: URL
        let clusterName: String
        let serverVersion: String
        let httpsCAFile: String
        let localCredentialsFile: String
        let nodes: [Node]
    }

    private struct LocalCredentials: Decodable {
        let username: String
        let password: String
        let totpSeed: String
    }

    private enum Failure: Error {
        case invalidFixture
        case invalidTOTP
        case deadline
        case outputLimit
    }

    /// Any attempt to use ordinary fingerprint trust must fail this live connection.
    private struct RefusePlainHostKeys: SSHHostKeyVerifying {
        func verify(_ candidate: SSHHostKeyCandidate) -> SSHHostKeyVerificationDecision {
            .approvalRequired
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func nativeLoginExecPTYResizeAndSFTPUseTheAppSSHSession() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VVTERM_TELEPORT_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: readFile(path, maximum: 262_144))
        guard fixture.schemaVersion == 1 else { throw Failure.invalidFixture }
        let credentials = try JSONDecoder().decode(
            LocalCredentials.self, from: readFile(fixture.localCredentialsFile, maximum: 16_384)
        )
        let ca = try certificateDER(readFile(fixture.httpsCAFile, maximum: 65_536))
        let proxy = try TeleportProxy(url: fixture.proxyURL, httpsCACertificatesDER: [ca])
        let client = TeleportClient(proxy: proxy, identityStore: MemoryIdentityStore())
        do {
            let discovery = try await client.discover()
            #expect(discovery.clusterName == fixture.clusterName)
            #expect(discovery.serverVersion == fixture.serverVersion)
            let identity = try await client.login(
                username: credentials.username, password: credentials.password,
                otp: totp(credentials.totpSeed)
            )
            let login = "teleport-test"
            try #require(identity.allowedLogins.contains(login))
            let expected = try #require(fixture.nodes.first { $0.authorized })
            let node = try await client.resolveNode(expected.id)
            #expect(node.id == expected.id)
            #expect(node.clusterName == fixture.clusterName)
            let connection = try await client.connect(to: node, login: login)
            let prepared = TeleportSSHPreparedConnection(connection: connection)
            let session = SSHSession(
                config: SSHSessionConfig(
                    host: node.id, port: 22, username: login, connectionMode: .teleport,
                    authMethod: nil, credentials: ServerCredentials(serverId: UUID()),
                    connectionTimeout: 20, keepAlive: .disabled
                ),
                hostKeyVerifier: RefusePlainHostKeys(), preparedConnection: prepared
            )
            do {
                try await withDeadline(session: session) {
                    try await session.connect()
                    try await checkCommand(session: session)
                    try await checkTerminal(session: session)
                    try await checkSFTP(session: session)
                }
                await session.disconnect()
                await prepared.close()
            } catch {
                session.abort()
                await session.disconnect()
                await prepared.close()
                throw error
            }
            try await client.signOut()
        } catch {
            try? await client.signOut()
            throw error
        }
    }

    private func checkCommand(session: SSHSession) async throws {
        var request = RemoteProcessRequest(payload: .rawShell(
            shell: .posix,
            command: "printf teleport-stdout; printf teleport-stderr >&2; exit 7",
            reason: .compatibility
        ))
        request.timeout = .seconds(15)
        request.outputLimit = .init(stdoutBytes: 1_024, stderrBytes: 1_024)
        let process = try await session.startProcess(request, shell: .posix(shellName: "sh"), mode: .collected)
        let result = try await process.wait()
        #expect(result.stdout == Data("teleport-stdout".utf8))
        #expect(result.stderr == Data("teleport-stderr".utf8))
        #expect(result.exitStatus == 7)
    }

    private func checkTerminal(session: SSHSession) async throws {
        // The marker confirms that the initial size and signal handler are ready.
        let probe = "sh -c 'test \"$(stty size)\" = \"24 80\" || exit 99; trap \"stty size; exit\" WINCH; printf \"<teleport-pty-ready>\\n\"; while :; do read -r ignored; done'"
        let shell = try await session.startShell(cols: 80, rows: 24, startupCommand: probe)
        var output = Data()
        var didResize = false
        for await chunk in shell.stream {
            guard chunk.count <= 4_096 - output.count else { throw Failure.outputLimit }
            output.append(chunk)
            if !didResize && output.range(of: Data("<teleport-pty-ready>".utf8)) != nil {
                didResize = true
                try await session.resize(cols: 121, rows: 43, for: shell.id)
            }
        }
        await session.closeShell(shell.id)
        #expect(didResize)
        let text = String(decoding: output, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        #expect(text == "<teleport-pty-ready>\n43 121\n")
    }

    private func checkSFTP(session: SSHSession) async throws {
        let path = "/tmp/teleport-app-" + UUID().uuidString
        let payload = Data((0..<262_144).map { UInt8($0 & 255) })
        try await session.writeFile(payload, to: path, permissions: 0o600)
        let returned = try await session.readFile(at: path, maxBytes: payload.count + 1)
        #expect(returned == payload)
        try await session.deleteFile(at: path)
    }

    private func withDeadline(
        session: SSHSession, operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                session.abort()
                throw Failure.deadline
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func readFile(_ path: String, maximum: Int) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0 && size <= maximum else { throw Failure.invalidFixture }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw Failure.invalidFixture }
        return data
    }

    private func certificateDER(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex),
              let der = Data(base64Encoded: text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }) else {
            throw Failure.invalidFixture
        }
        return der
    }

    private func totp(_ seed: String) throws -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var key = Data(), accumulator: UInt32 = 0, bits = 0
        for byte in seed.uppercased().utf8 where byte != 61 {
            guard let digit = alphabet.firstIndex(of: byte) else { throw Failure.invalidTOTP }
            accumulator = (accumulator << 5) | UInt32(digit)
            bits += 5
            if bits >= 8 {
                bits -= 8
                key.append(UInt8((accumulator >> bits) & 255))
                accumulator &= (1 << bits) - 1
            }
        }
        guard !key.isEmpty, bits == 0 || accumulator == 0 else { throw Failure.invalidTOTP }
        var counter = UInt64(Date().timeIntervalSince1970 / 30).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        guard let last = digest.last else { throw Failure.invalidTOTP }
        let offset = Int(last & 15)
        let value = ((UInt32(digest[offset]) & 127) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        return String(format: "%06u", value % 1_000_000)
    }
}
#endif
