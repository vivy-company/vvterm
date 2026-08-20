import Foundation
import Testing
@testable import VVTerm

private actor ServerConnectionTesterFake: ServerConnectionTesting {
    private var continuations: [CheckedContinuation<ServerConnectionTestResult, Never>] = []

    func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if continuations.count >= count { return true }
            await Task.yield()
        }
        return continuations.count >= count
    }

    func complete(call index: Int, with result: ServerConnectionTestResult) {
        continuations[index].resume(returning: result)
    }
}

private final class ServerHostKeyRepositoryFake: ServerHostKeyRepository, @unchecked Sendable {
    private let lock = NSLock()
    private let challenge: KnownHostsManager.Challenge?
    private let approvalResult: Bool
    private var approvedAtStorage: Date?
    private var rejectedStorage: KnownHostsManager.Challenge?

    init(
        challenge: KnownHostsManager.Challenge? = nil,
        approvalResult: Bool = true
    ) {
        self.challenge = challenge
        self.approvalResult = approvalResult
    }

    var approvedAt: Date? {
        lock.withLock { approvedAtStorage }
    }

    func pendingChallenge(for host: String, port: Int, now: Date) -> KnownHostsManager.Challenge? {
        challenge
    }

    func approve(_ challenge: KnownHostsManager.Challenge, now: Date) -> Bool {
        lock.withLock { approvedAtStorage = now }
        return approvalResult
    }

    func reject(_ challenge: KnownHostsManager.Challenge) {
        lock.withLock { rejectedStorage = challenge }
    }
}

private final class ServerOperationIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingIDs: [UUID]

    init(_ ids: [UUID]) {
        remainingIDs = ids
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!remainingIDs.isEmpty, "Missing test operation ID")
            return remainingIDs.removeFirst()
        }
    }
}

@MainActor
private final class ServerMutationRepositoryGate: ServerMutationRepository {
    private var continuation: CheckedContinuation<Server, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {}

    func server(id: UUID) -> Server? {
        nil
    }

    func apply(
        _ mutation: ServerMutation,
        credentials: ServerCredentials
    ) async throws -> Server {
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with server: Server) {
        continuation?.resume(returning: server)
        continuation = nil
    }
}

@MainActor
private final class ServerCredentialStoreStub: ServerCredentialTransactionRepository {
    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {}

    func getCredentials(for server: Server) throws -> ServerCredentials {
        ServerCredentials(serverId: server.id)
    }

    func deleteCredentials(for serverID: UUID) throws {}
}

@MainActor
private final class ServerFormCredentialLoaderStub: ServerFormCredentialLoading {
    func loadFormCredentials(for server: Server?) async throws -> ServerFormCredentialLoad {
        ServerFormCredentialLoad(storedKeys: [], savedCredentials: .notRequested)
    }

    func loadStoredKey(_ entry: SSHKeyEntry) async throws -> ServerFormStoredKeyLoad {
        ServerFormStoredKeyLoad(
            id: entry.id,
            privateKey: nil,
            passphrase: nil,
            publicKey: entry.publicKey ?? ""
        )
    }
}

@MainActor
private final class ControlledServerFormCredentialLoader: ServerFormCredentialLoading {
    private struct FormLoadRequest {
        let server: Server?
        let continuation: CheckedContinuation<ServerFormCredentialLoad, Error>
    }

    private struct StoredKeyLoadRequest {
        let entry: SSHKeyEntry
        let continuation: CheckedContinuation<ServerFormStoredKeyLoad, Error>
    }

    private var formLoadRequests: [FormLoadRequest] = []
    private var storedKeyLoadRequests: [StoredKeyLoadRequest] = []

    func loadFormCredentials(for server: Server?) async throws -> ServerFormCredentialLoad {
        try await withCheckedThrowingContinuation { continuation in
            formLoadRequests.append(FormLoadRequest(server: server, continuation: continuation))
        }
    }

    func loadStoredKey(_ entry: SSHKeyEntry) async throws -> ServerFormStoredKeyLoad {
        try await withCheckedThrowingContinuation { continuation in
            storedKeyLoadRequests.append(
                StoredKeyLoadRequest(entry: entry, continuation: continuation)
            )
        }
    }

    func waitForFormLoadCallCount(_ count: Int) async -> Bool {
        await waitUntil { formLoadRequests.count >= count }
    }

    func waitForStoredKeyLoadCallCount(_ count: Int) async -> Bool {
        await waitUntil { storedKeyLoadRequests.count >= count }
    }

    func completeFormLoad(
        call index: Int,
        with result: ServerFormCredentialLoad
    ) {
        formLoadRequests[index].continuation.resume(returning: result)
    }

    func completeStoredKeyLoad(
        call index: Int,
        with result: Result<ServerFormStoredKeyLoad, Error>
    ) {
        switch result {
        case .success(let load):
            storedKeyLoadRequests[index].continuation.resume(returning: load)
        case .failure(let error):
            storedKeyLoadRequests[index].continuation.resume(throwing: error)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class ServerCredentialRepositoryFake: ServerCredentialRepository {
    var storedKeys: [SSHKeyEntry] = []
    var storedKeyData: [UUID: (key: Data, passphrase: String?)] = [:]
    var savedCredentials: ServerCredentials?
    var savedCredentialError: Error?

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {}

    func getCredentials(for server: Server) throws -> ServerCredentials {
        if let savedCredentialError { throw savedCredentialError }
        return savedCredentials ?? ServerCredentials(serverId: server.id)
    }

    func deleteCredentials(for serverID: UUID) throws {}

    func getStoredSSHKeys() -> [SSHKeyEntry] {
        storedKeys
    }

    func getStoredSSHKeyData(for id: UUID) throws -> (key: Data, passphrase: String?)? {
        storedKeyData[id]
    }
}

private struct ServerCredentialRepositoryTestError: LocalizedError {
    var errorDescription: String? { "Repository failed" }
}

@Suite(.serialized)
@MainActor
struct ServerFormOperationControllerTests {
    @Test
    func credentialLoadPublishesStoredKeyCatalogAndSavedCredentials() async {
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let loader = ControlledServerFormCredentialLoader()
        let controller = makeController(
            credentialLoader: loader,
            connectionTester: ServerConnectionTesterFake(),
            operationIDs: [operationID]
        )
        let key = SSHKeyEntry(name: "Work key")
        let input = makeInput(host: "saved.example.com")
        var savedCredentials = ServerCredentials(serverId: input.server.id)
        savedCredentials.password = "saved-secret"
        var loadedCredentials: ServerCredentials?

        controller.loadFormCredentials(for: input.server) {
            loadedCredentials = $0
        }
        #expect(controller.phase == .loadingCredentials(id: operationID))
        #expect(await loader.waitForFormLoadCallCount(1))
        loader.completeFormLoad(
            call: 0,
            with: ServerFormCredentialLoad(
                storedKeys: [key],
                savedCredentials: .loaded(savedCredentials, selectedStoredKeyID: nil)
            )
        )

        #expect(await waitUntil { controller.phase == .idle })
        #expect(controller.storedKeys == [key])
        #expect(loadedCredentials?.password == "saved-secret")
    }

    @Test
    func liveCredentialLoaderMatchesSavedStoredKey() async throws {
        let repository = ServerCredentialRepositoryFake()
        let key = SSHKeyEntry(name: "Matched key", hasPassphrase: true)
        let input = makeInput(host: "key.example.com")
        var server = input.server
        server.authMethod = .sshKeyWithPassphrase
        let privateKey = Data("private-key".utf8)
        var credentials = ServerCredentials(serverId: server.id)
        credentials.privateKey = privateKey
        credentials.passphrase = "secret"
        repository.storedKeys = [key]
        repository.storedKeyData[key.id] = (privateKey, "secret")
        repository.savedCredentials = credentials

        let load = try await ServerFormCredentialLoader(repository: repository)
            .loadFormCredentials(for: server)

        #expect(load.storedKeys == [key])
        guard case .loaded(let loadedCredentials, let selectedStoredKeyID) = load.savedCredentials else {
            Issue.record("Saved credentials did not load")
            return
        }
        #expect(loadedCredentials.privateKey == privateKey)
        #expect(selectedStoredKeyID == key.id)
    }

    @Test
    func savedCredentialFailureKeepsTheStoredKeyCatalogVisible() async throws {
        let repository = ServerCredentialRepositoryFake()
        let key = SSHKeyEntry(name: "Available key")
        repository.storedKeys = [key]
        repository.savedCredentialError = ServerCredentialRepositoryTestError()
        let server = makeInput(host: "failure.example.com").server

        let load = try await ServerFormCredentialLoader(repository: repository)
            .loadFormCredentials(for: server)

        #expect(load.storedKeys == [key])
        guard case .failed(let message) = load.savedCredentials else {
            Issue.record("Repository failure was not preserved")
            return
        }
        #expect(message == "Repository failed")
    }

    @Test
    func replacementRejectsTheCancelledCredentialLoadsLateCompletion() async {
        let firstOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let secondOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let loader = ControlledServerFormCredentialLoader()
        let controller = makeController(
            credentialLoader: loader,
            connectionTester: ServerConnectionTesterFake(),
            operationIDs: [firstOperationID, secondOperationID]
        )
        let firstKey = SSHKeyEntry(name: "First")
        let secondKey = SSHKeyEntry(name: "Second")
        var callbackCount = 0

        controller.loadFormCredentials(for: nil) { _ in callbackCount += 1 }
        #expect(await loader.waitForFormLoadCallCount(1))
        controller.loadFormCredentials(for: nil) { _ in callbackCount += 1 }
        #expect(await loader.waitForFormLoadCallCount(2))

        loader.completeFormLoad(
            call: 0,
            with: ServerFormCredentialLoad(
                storedKeys: [firstKey],
                savedCredentials: .notRequested
            )
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.phase == .loadingCredentials(id: secondOperationID))
        #expect(controller.storedKeys.isEmpty)

        loader.completeFormLoad(
            call: 1,
            with: ServerFormCredentialLoad(
                storedKeys: [secondKey],
                savedCredentials: .notRequested
            )
        )
        #expect(await waitUntil { controller.phase == .idle })
        #expect(controller.storedKeys == [secondKey])
        #expect(callbackCount == 0)
    }

    @Test
    func credentialIntentRejectsLateInitialCredentialCompletion() async {
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000108")!
        let loader = ControlledServerFormCredentialLoader()
        let controller = makeController(
            credentialLoader: loader,
            connectionTester: ServerConnectionTesterFake(),
            operationIDs: [operationID]
        )
        let lateKey = SSHKeyEntry(name: "Late")
        var loadedCredentials: ServerCredentials?

        controller.loadFormCredentials(for: makeInput(host: "edit.example.com").server) {
            loadedCredentials = $0
        }
        #expect(await loader.waitForFormLoadCallCount(1))
        controller.invalidateCredentialLoading()
        loader.completeFormLoad(
            call: 0,
            with: ServerFormCredentialLoad(
                storedKeys: [lateKey],
                savedCredentials: .loaded(
                    ServerCredentials(serverId: UUID()),
                    selectedStoredKeyID: lateKey.id
                )
            )
        )
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.phase == .idle)
        #expect(controller.storedKeys.isEmpty)
        #expect(controller.selectedStoredKeyID == nil)
        #expect(loadedCredentials?.serverId == nil)
    }

    @Test
    func connectionTestRejectsLateInitialCredentialCompletion() async {
        let credentialOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000109")!
        let testOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000110")!
        let loader = ControlledServerFormCredentialLoader()
        let tester = ServerConnectionTesterFake()
        let controller = makeController(
            credentialLoader: loader,
            connectionTester: tester,
            operationIDs: [credentialOperationID, testOperationID]
        )
        let input = makeInput(host: "test.example.com")
        var credentialCallbackCount = 0

        controller.loadFormCredentials(for: input.server) { _ in
            credentialCallbackCount += 1
        }
        #expect(await loader.waitForFormLoadCallCount(1))
        controller.startConnectionTest(
            server: input.server,
            credentials: input.credentials,
            snapshot: input.snapshot
        )
        #expect(await tester.waitForCallCount(1))

        loader.completeFormLoad(
            call: 0,
            with: ServerFormCredentialLoad(
                storedKeys: [SSHKeyEntry(name: "Late")],
                savedCredentials: .loaded(input.credentials, selectedStoredKeyID: nil)
            )
        )
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.phase == .testing(id: testOperationID, snapshot: input.snapshot))
        #expect(controller.storedKeys.isEmpty)
        #expect(credentialCallbackCount == 0)

        await tester.complete(call: 0, with: .success)
        #expect(await waitUntil { controller.phase == .testSucceeded(snapshot: input.snapshot) })
    }

    @Test
    func clearingStoredKeySelectionRejectsLateKeyData() async {
        let catalogOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let keyOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let loader = ControlledServerFormCredentialLoader()
        let controller = makeController(
            credentialLoader: loader,
            connectionTester: ServerConnectionTesterFake(),
            operationIDs: [catalogOperationID, keyOperationID]
        )
        let key = SSHKeyEntry(name: "Cancelled")
        var loadedKey: ServerFormStoredKeyLoad?

        controller.loadFormCredentials(for: nil) { _ in }
        #expect(await loader.waitForFormLoadCallCount(1))
        loader.completeFormLoad(
            call: 0,
            with: ServerFormCredentialLoad(
                storedKeys: [key],
                savedCredentials: .notRequested
            )
        )
        #expect(await waitUntil { controller.phase == .idle })

        controller.selectStoredKey(id: key.id) { loadedKey = $0 }
        #expect(await loader.waitForStoredKeyLoadCallCount(1))
        controller.clearStoredKeySelection()
        loader.completeStoredKeyLoad(
            call: 0,
            with: .success(
                ServerFormStoredKeyLoad(
                    id: key.id,
                    privateKey: "late-key",
                    passphrase: nil,
                    publicKey: ""
                )
            )
        )
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.phase == .idle)
        #expect(controller.selectedStoredKeyID == nil)
        #expect(loadedKey?.id == nil)
    }

    @Test
    func storedKeyRepositoryFailureUsesTheStoredKeyFailurePhase() async {
        let catalogOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let keyOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000107")!
        let loader = ControlledServerFormCredentialLoader()
        let controller = makeController(
            credentialLoader: loader,
            connectionTester: ServerConnectionTesterFake(),
            operationIDs: [catalogOperationID, keyOperationID]
        )
        let key = SSHKeyEntry(name: "Unreadable")

        controller.loadFormCredentials(for: nil) { _ in }
        #expect(await loader.waitForFormLoadCallCount(1))
        loader.completeFormLoad(
            call: 0,
            with: ServerFormCredentialLoad(
                storedKeys: [key],
                savedCredentials: .notRequested
            )
        )
        #expect(await waitUntil { controller.phase == .idle })

        controller.selectStoredKey(id: key.id) { _ in }
        #expect(await loader.waitForStoredKeyLoadCallCount(1))
        loader.completeStoredKeyLoad(
            call: 0,
            with: .failure(ServerCredentialRepositoryTestError())
        )

        #expect(
            await waitUntil {
                controller.phase == .failed(.storedKeyLoad(message: "Repository failed"))
            }
        )
    }

    @Test
    func replacementRejectsTheCancelledTestsLateCompletion() async {
        let firstOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tester = ServerConnectionTesterFake()
        let controller = makeController(
            connectionTester: tester,
            operationIDs: [firstOperationID, secondOperationID]
        )
        let first = makeInput(host: "first.example.com")
        let second = makeInput(host: "second.example.com")

        controller.startConnectionTest(
            server: first.server,
            credentials: first.credentials,
            snapshot: first.snapshot
        )
        #expect(controller.phase == .testing(id: firstOperationID, snapshot: first.snapshot))
        #expect(await tester.waitForCallCount(1))

        controller.startConnectionTest(
            server: second.server,
            credentials: second.credentials,
            snapshot: second.snapshot
        )
        #expect(await tester.waitForCallCount(2))

        await tester.complete(call: 0, with: .success)
        for _ in 0..<20 { await Task.yield() }

        guard case .testing(let activeID, let activeSnapshot) = controller.phase else {
            Issue.record("The replacement test is no longer active")
            return
        }
        #expect(activeID == secondOperationID)
        #expect(activeSnapshot == second.snapshot)

        let failure = ServerConnectionTestFailure(
            reason: .message("Second failed"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )
        await tester.complete(call: 1, with: .failure(failure))
        #expect(await waitUntil { controller.connectionTestFailure == failure })
    }

    @Test
    func cancellationRejectsALateConnectionTestCompletion() async {
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let tester = ServerConnectionTesterFake()
        let controller = makeController(
            connectionTester: tester,
            operationIDs: [operationID]
        )
        let input = makeInput(host: "cancelled.example.com")

        controller.startConnectionTest(
            server: input.server,
            credentials: input.credentials,
            snapshot: input.snapshot
        )
        #expect(await tester.waitForCallCount(1))

        controller.cancel()
        await tester.complete(call: 0, with: .success)
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.phase == .idle)
    }

    @Test
    func hostKeyApprovalUsesTheInjectedClockAndRepository() async {
        let fixedNow = Date(timeIntervalSince1970: 42)
        let challenge = KnownHostsManager.Challenge(
            id: UUID(),
            host: "host.example.com",
            port: 22,
            fingerprint: "SHA256:test",
            keyType: 0,
            keyTypeName: "ssh-ed25519",
            kind: .firstUse,
            createdAt: fixedNow
        )
        let tester = ServerConnectionTesterFake()
        let hostKeys = ServerHostKeyRepositoryFake(challenge: challenge)
        let controller = makeController(
            connectionTester: tester,
            hostKeys: hostKeys,
            now: { fixedNow },
            operationIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000004")!]
        )
        let input = makeInput(host: challenge.host)
        let failure = ServerConnectionTestFailure(
            reason: .message("Approval required"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: challenge
        )

        controller.startConnectionTest(
            server: input.server,
            credentials: input.credentials,
            snapshot: input.snapshot
        )
        #expect(await tester.waitForCallCount(1))
        await tester.complete(call: 0, with: .failure(failure))
        #expect(await waitUntil { controller.hostKeyChallenge == challenge })

        #expect(controller.approveHostKeyChallenge())
        #expect(hostKeys.approvedAt == fixedNow)
        #expect(controller.phase == .idle)
    }

    @Test
    func expiredHostKeyApprovalStoresASemanticFailureReason() async {
        let challenge = KnownHostsManager.Challenge(
            id: UUID(),
            host: "expired.example.com",
            port: 22,
            fingerprint: "SHA256:expired",
            keyType: 0,
            keyTypeName: "ssh-ed25519",
            kind: .firstUse,
            createdAt: .distantPast
        )
        let tester = ServerConnectionTesterFake()
        let controller = makeController(
            connectionTester: tester,
            hostKeys: ServerHostKeyRepositoryFake(
                challenge: challenge,
                approvalResult: false
            ),
            operationIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000005")!]
        )
        let input = makeInput(host: challenge.host)
        let approvalRequired = ServerConnectionTestFailure(
            reason: .message("Approval required"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: challenge
        )

        controller.startConnectionTest(
            server: input.server,
            credentials: input.credentials,
            snapshot: input.snapshot
        )
        #expect(await tester.waitForCallCount(1))
        await tester.complete(call: 0, with: .failure(approvalRequired))
        #expect(await waitUntil { controller.hostKeyChallenge == challenge })

        #expect(!controller.approveHostKeyChallenge())
        #expect(
            controller.connectionTestFailure?.reason == .hostKeyApprovalExpired
        )
    }

    @Test
    func cancellationRejectsALateSaveCompletion() async {
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let tester = ServerConnectionTesterFake()
        let mutations = ServerMutationRepositoryGate()
        let controller = makeController(
            connectionTester: tester,
            mutations: mutations,
            operationIDs: [operationID]
        )
        let input = makeInput(host: "save.example.com")
        var savedServer: Server?

        controller.save(
            mutation: .create(input.server),
            credentials: input.credentials,
            hasProAccess: true,
            authorize: { true },
            onSaved: { savedServer = $0 }
        )
        #expect(controller.phase == .saving(id: operationID))
        await mutations.waitUntilStarted()

        controller.cancel()
        mutations.succeed(with: input.server)
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.phase == .idle)
        #expect(savedServer == nil)
    }

    private func makeController(
        credentialLoader: (any ServerFormCredentialLoading)? = nil,
        connectionTester: any ServerConnectionTesting,
        hostKeys: any ServerHostKeyRepository = ServerHostKeyRepositoryFake(),
        mutations: (any ServerMutationRepository)? = nil,
        now: @escaping @Sendable () -> Date = { .distantPast },
        operationIDs: [UUID]
    ) -> ServerFormOperationController {
        let idSequence = ServerOperationIDSequence(operationIDs)
        return ServerFormOperationController(
            credentialLoader: credentialLoader ?? ServerFormCredentialLoaderStub(),
            connectionTester: connectionTester,
            hostKeys: hostKeys,
            saveUseCase: ServerSaveUseCase(
                mutations: mutations ?? ServerMutationRepositoryGate()
            ),
            now: now,
            makeID: { idSequence.next() }
        )
    }

    private func makeInput(
        host: String
    ) -> (server: Server, credentials: ServerCredentials, snapshot: ServerFormModel.ConnectionSnapshot) {
        let workspaceID = UUID()
        let serverID = UUID()
        var form = ServerFormModel(
            workspaceID: workspaceID,
            defaultTmuxEnabled: true,
            defaultTmuxStartupBehavior: .vvtermManaged
        )
        form.name = host
        form.host = host
        form.password = "secret"
        return (
            form.makeServer(id: serverID, workspaceID: workspaceID, createdAt: .distantPast),
            form.makeCredentials(serverID: serverID),
            form.connectionSnapshot
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
