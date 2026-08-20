import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerSaveUseCaseTests {
    @Test
    func createValidatesThenCommitsMutationWithCredentials() async throws {
        var events: [String] = []
        let repository = ServerMutationRepositoryFake(events: { events.append($0) })
        let useCase = ServerSaveUseCase(mutations: repository)
        let server = makeServer()
        var credentials = ServerCredentials(serverId: server.id)
        credentials.password = "secret"

        let saved = try await useCase.execute(
            .create(server),
            credentials: credentials,
            hasProAccess: true
        )

        #expect(saved == server)
        #expect(repository.validatedHasProAccess == true)
        #expect(repository.appliedMutation == .create(server))
        #expect(repository.appliedPassword == "secret")
        #expect(events == ["validate", "apply"])
    }

    @Test
    func validationFailureDoesNotCommitMutation() async {
        let repository = ServerMutationRepositoryFake()
        repository.validationError = TestFailure.rejected
        let useCase = ServerSaveUseCase(mutations: repository)
        let server = makeServer()

        await #expect(throws: TestFailure.self) {
            try await useCase.execute(
                .create(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: false
            )
        }

        #expect(repository.appliedMutation == nil)
    }

    @Test
    func updateUsesExplicitUpdateMutation() async throws {
        let repository = ServerMutationRepositoryFake()
        let useCase = ServerSaveUseCase(mutations: repository)
        let server = makeServer()

        _ = try await useCase.execute(
            .update(server),
            credentials: ServerCredentials(serverId: server.id),
            hasProAccess: false
        )

        #expect(repository.appliedMutation == .update(server))
    }

    @Test
    func transactionFailureIsReturned() async {
        let repository = ServerMutationRepositoryFake()
        repository.applyError = TestFailure.transaction
        let useCase = ServerSaveUseCase(mutations: repository)
        let server = makeServer()

        await #expect(throws: TestFailure.self) {
            try await useCase.execute(
                .create(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: true
            )
        }
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            username: "root"
        )
    }
}

@MainActor
private final class ServerMutationRepositoryFake: ServerMutationRepository {
    var validationError: Error?
    var applyError: Error?
    var validatedHasProAccess: Bool?
    var appliedMutation: ServerMutation?
    var appliedPassword: String?

    private let events: (String) -> Void

    init(events: @escaping (String) -> Void = { _ in }) {
        self.events = events
    }

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {
        events("validate")
        validatedHasProAccess = hasProAccess
        if let validationError { throw validationError }
    }

    func apply(
        _ mutation: ServerMutation,
        credentials: ServerCredentials
    ) async throws -> Server {
        events("apply")
        appliedMutation = mutation
        appliedPassword = credentials.password
        if let applyError { throw applyError }
        return mutation.server
    }

    func server(id: UUID) -> Server? { nil }
}

private enum TestFailure: Error {
    case rejected
    case transaction
}
