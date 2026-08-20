actor SSHConnectionOperationService {
    private let clientFactory: SSHClientFactory

    init(clientFactory: SSHClientFactory) {
        self.clientFactory = clientFactory
    }

    func runWithConnection<T: Sendable>(
        using client: SSHClient,
        server: Server,
        credentials: ServerCredentials,
        disconnectWhenDone: Bool = false,
        operation: @escaping @Sendable (SSHClient) async throws -> T
    ) async throws -> T {
        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let result = try await operation(client)
            if disconnectWhenDone {
                await client.disconnect()
            }
            return result
        } catch {
            if disconnectWhenDone {
                await client.disconnect()
            }
            throw error
        }
    }

    func withTemporaryConnection<T: Sendable>(
        server: Server,
        credentials: ServerCredentials,
        operation: @escaping @Sendable (SSHClient) async throws -> T
    ) async throws -> T {
        let client = clientFactory.makeClient()
        return try await runWithConnection(
            using: client,
            server: server,
            credentials: credentials,
            disconnectWhenDone: true,
            operation: operation
        )
    }
}
