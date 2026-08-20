import Foundation

@MainActor
final class SSHSFTPAdapter {
    typealias BorrowedClientProvider = @MainActor @Sendable (UUID) -> SSHClient?

    private enum ClientOwnership {
        case borrowed
        case owned
    }

    private struct ClientRegistration {
        let client: SSHClient
        let ownership: ClientOwnership
    }

    private var clients: [UUID: ClientRegistration] = [:]
    private let borrowedClientProvider: BorrowedClientProvider
    private let credentialRepository: any ServerCredentialTransactionRepository
    private let connectionOperations: SSHConnectionOperationService
    private let clientFactory: SSHClientFactory

    init(
        borrowedClientProvider: @escaping BorrowedClientProvider,
        credentialRepository: any ServerCredentialTransactionRepository,
        connectionOperations: SSHConnectionOperationService,
        clientFactory: SSHClientFactory
    ) {
        self.borrowedClientProvider = borrowedClientProvider
        self.credentialRepository = credentialRepository
        self.connectionOperations = connectionOperations
        self.clientFactory = clientFactory
    }

    func withService<T: Sendable>(
        for server: Server,
        operation: @MainActor @escaping @Sendable (any RemoteFileService) async throws -> T
    ) async throws -> T {
        let registration = clientRegistration(for: server)
        let credentials = try credentialRepository.getCredentials(for: server)

        do {
            return try await connectionOperations.runWithConnection(
                using: registration.client,
                server: server,
                credentials: credentials,
                disconnectWhenDone: false
            ) { client in
                try await operation(SFTPRemoteFileService(client: client))
            }
        } catch {
            if registration.ownership == .borrowed {
                clients.removeValue(forKey: server.id)
            }
            throw error
        }
    }

    func disconnect(serverId: UUID) {
        guard let registration = clients.removeValue(forKey: serverId) else { return }
        guard registration.ownership == .owned else { return }

        Task.detached(priority: .utility) {
            await registration.client.disconnect()
        }
    }

    private func borrowedClient(for serverId: UUID) -> SSHClient? {
        borrowedClientProvider(serverId)
    }

    private func clientRegistration(for server: Server) -> ClientRegistration {
        if let borrowedClient = borrowedClient(for: server.id) {
            if let existing = clients[server.id], existing.client === borrowedClient {
                return existing
            }

            let registration = ClientRegistration(client: borrowedClient, ownership: .borrowed)
            clients[server.id] = registration
            return registration
        }

        if let existing = clients[server.id], existing.ownership == .owned {
            return existing
        }

        let registration = ClientRegistration(
            client: clientFactory.makeClient(),
            ownership: .owned
        )
        clients[server.id] = registration
        return registration
    }
}
