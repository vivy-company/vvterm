import ETBootstrap
import Foundation

nonisolated enum EternalTerminalHostCompatibility: Equatable {
    case supported
    case unsupportedNativeWindows
    case unsupportedShell

    init(environment: RemoteEnvironment) {
        if environment.platform == .windows {
            self = .unsupportedNativeWindows
        } else if environment.shellProfile.supportsPOSIXExecWrapper {
            self = .supported
        } else {
            self = .unsupportedShell
        }
    }

    var bootstrapDiagnostic: String? {
        switch self {
        case .supported:
            nil
        case .unsupportedNativeWindows:
            "VVTERM_ET_UNSUPPORTED_NATIVE_WINDOWS"
        case .unsupportedShell:
            "VVTERM_ET_REQUIRES_POSIX_SHELL"
        }
    }
}

/// Runs swift-et's SSH bootstrap and auxiliary remote operations through VVTerm's SSH stack.
actor SSHETBootstrapExecutor: ETBootstrapExecutor {
    nonisolated static var bootstrapOptions: ETBootstrapOptions {
        ETBootstrapOptions(etterminalPath: "etterminal --logtostdout")
    }

    private let client: SSHClient
    private let connection: Connection?
    private let startupPlanProvider: (@Sendable (SSHClient) async throws -> TerminalShellStartupPlan)?
    private var startupPlan: TerminalShellStartupPlan = .plainShell
    private var terminalType = RemoteTerminalBootstrap.defaultTerminalType

    private struct Connection: Sendable {
        let server: Server
        let credentials: ServerCredentials
    }

    init(
        server: Server,
        credentials: ServerCredentials,
        client: SSHClient,
        startupPlanProvider: (@Sendable (SSHClient) async throws -> TerminalShellStartupPlan)? = nil
    ) {
        self.client = client
        connection = Connection(server: server, credentials: credentials)
        self.startupPlanProvider = startupPlanProvider
    }

    /// Used while a caller already owns the temporary SSH connection lifecycle.
    init(connectedClient: SSHClient) {
        client = connectedClient
        connection = nil
        startupPlanProvider = nil
    }

    func preparedStartupPlan() -> TerminalShellStartupPlan {
        startupPlan
    }

    func preparedTerminalType() -> RemoteTerminalType {
        terminalType
    }

    func run(command: String) async throws -> String {
        let command = Self.remoteBootstrapCommand(command)
        guard let connection else {
            return try await client.execute(command, timeout: .seconds(20))
        }

        do {
            _ = try await client.connect(
                to: connection.server,
                credentials: connection.credentials
            )
            let compatibility = EternalTerminalHostCompatibility(
                environment: await client.remoteEnvironment()
            )
            if let diagnostic = compatibility.bootstrapDiagnostic {
                await client.disconnect()
                return diagnostic
            }
            terminalType = await client.remoteTerminalType()
            if let startupPlanProvider {
                startupPlan = try await startupPlanProvider(client)
            }
            let output = try await client.execute(command, timeout: .seconds(20))
            await client.disconnect()
            return output
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Use a known POSIX shell even when the account's login shell is fish, and
    /// make common package-manager locations available to non-interactive SSH.
    nonisolated static func remoteBootstrapCommand(_ command: String) -> String {
        let script = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if ! command -v etterminal >/dev/null 2>&1; then
          printf 'etterminal was not found in the remote PATH';
          exit 127;
        fi;
        \(command)
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    func withConnectedClient<Result: Sendable>(
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        guard let connection else {
            return try await operation(client)
        }
        return try await withConnectedClient(connection: connection, operation)
    }

    private func withConnectedClient<Result: Sendable>(
        connection: Connection,
        _ operation: @Sendable (SSHClient) async throws -> Result
    ) async throws -> Result {
        do {
            _ = try await client.connect(
                to: connection.server,
                credentials: connection.credentials
            )
            let result = try await operation(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }
}
