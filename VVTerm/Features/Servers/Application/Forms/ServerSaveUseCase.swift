import Foundation

nonisolated enum ServerMutation: Equatable, Sendable {
    case create(Server)
    case update(Server)

    var server: Server {
        switch self {
        case .create(let server), .update(let server):
            return server
        }
    }
}

@MainActor
protocol ServerMutationRepository: AnyObject {
    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws
    func server(id: UUID) -> Server?
    func apply(
        _ mutation: ServerMutation,
        credentials: ServerCredentials
    ) async throws -> Server
}

@MainActor
protocol ServerCredentialStoring: AnyObject {
    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws
}

@MainActor
protocol ServerCredentialTransactionRepository: ServerCredentialStoring {
    func getCredentials(for server: Server) throws -> ServerCredentials
    func deleteCredentials(for serverID: UUID) throws
}

@MainActor
protocol ServerCredentialRepository: ServerCredentialTransactionRepository {
    func getStoredSSHKeys() -> [SSHKeyEntry]
    func getStoredSSHKeyData(for id: UUID) throws -> (key: Data, passphrase: String?)?
}

@MainActor
struct ServerSaveUseCase {
    private let mutations: any ServerMutationRepository

    init(mutations: any ServerMutationRepository) {
        self.mutations = mutations
    }

    func execute(
        _ mutation: ServerMutation,
        credentials newCredentials: ServerCredentials,
        hasProAccess: Bool
    ) async throws -> Server {
        try mutations.validate(mutation, hasProAccess: hasProAccess)
        return try await mutations.apply(mutation, credentials: newCredentials)
    }
}
