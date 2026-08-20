import Combine
import Foundation

nonisolated enum ServerConnectionTestFailureReason: Equatable, Sendable {
    case message(String)
    case tailscale(String)
    case eternalTerminal(
        failure: EternalTerminalSessionFailure,
        host: String,
        port: Int
    )
    case hostKeyApprovalExpired
}

nonisolated struct ServerConnectionTestFailure: Equatable, Sendable {
    let reason: ServerConnectionTestFailureReason
    let requiresCloudflareOverrides: Bool
    let hostKeyChallenge: KnownHostsManager.Challenge?
}

nonisolated enum ServerConnectionTestResult: Equatable, Sendable {
    case success
    case failure(ServerConnectionTestFailure)
    case cancelled
}

nonisolated protocol ServerConnectionTesting: Sendable {
    func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult
}

nonisolated protocol ServerHostKeyRepository: Sendable {
    func pendingChallenge(for host: String, port: Int, now: Date) -> KnownHostsManager.Challenge?
    func approve(_ challenge: KnownHostsManager.Challenge, now: Date) -> Bool
    func reject(_ challenge: KnownHostsManager.Challenge)
}

@MainActor
struct ServerFormDependencies {
    let credentials: any ServerCredentialRepository
    let connectionTester: any ServerConnectionTesting
    let hostKeys: any ServerHostKeyRepository
    let defaultTmuxEnabled: @MainActor () -> Bool
    let defaultTmuxStartupBehavior: @MainActor () -> TmuxStartupBehavior
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID
}

nonisolated enum ServerFormOperationFailure: Equatable, Sendable {
    case operation(message: String)
    case credentialLoad(message: String)
    case storedKeyLoad(message: String)
}

nonisolated enum ServerFormOperationPhase: Equatable, Sendable {
    case idle
    case loadingCredentials(id: UUID)
    case testing(id: UUID, snapshot: ServerFormModel.ConnectionSnapshot)
    case testSucceeded(snapshot: ServerFormModel.ConnectionSnapshot)
    case testFailed(snapshot: ServerFormModel.ConnectionSnapshot, failure: ServerConnectionTestFailure)
    case saving(id: UUID)
    case failed(ServerFormOperationFailure)
    case requiresUpgrade
}

@MainActor
final class ServerFormOperationController: ObservableObject {
    @Published private(set) var phase: ServerFormOperationPhase = .idle
    @Published private(set) var storedKeys: [SSHKeyEntry] = []
    @Published private(set) var selectedStoredKeyID: UUID?

    private let credentialLoader: any ServerFormCredentialLoading
    private let connectionTester: any ServerConnectionTesting
    private let hostKeys: any ServerHostKeyRepository
    private let saveUseCase: ServerSaveUseCase
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private var credentialLoadTask: Task<Void, Never>?
    private var connectionTestTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(
        credentialLoader: any ServerFormCredentialLoading,
        connectionTester: any ServerConnectionTesting,
        hostKeys: any ServerHostKeyRepository,
        saveUseCase: ServerSaveUseCase,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID
    ) {
        self.credentialLoader = credentialLoader
        self.connectionTester = connectionTester
        self.hostKeys = hostKeys
        self.saveUseCase = saveUseCase
        self.now = now
        self.makeID = makeID
    }

    deinit {
        credentialLoadTask?.cancel()
        connectionTestTask?.cancel()
        saveTask?.cancel()
    }

    var isLoadingCredentials: Bool {
        if case .loadingCredentials = phase { return true }
        return false
    }

    var isTestingConnection: Bool {
        if case .testing = phase { return true }
        return false
    }

    var isSaving: Bool {
        if case .saving = phase { return true }
        return false
    }

    var requiresUpgrade: Bool {
        phase == .requiresUpgrade
    }

    var failure: ServerFormOperationFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    var connectionTestFailure: ServerConnectionTestFailure? {
        if case .testFailed(_, let failure) = phase { return failure }
        return nil
    }

    var hostKeyChallenge: KnownHostsManager.Challenge? {
        connectionTestFailure?.hostKeyChallenge
    }

    func hasValidConnectionTest(for snapshot: ServerFormModel.ConnectionSnapshot) -> Bool {
        guard case .testSucceeded(let completedSnapshot) = phase else { return false }
        return completedSnapshot == snapshot
    }

    func clearPresentation() {
        switch phase {
        case .failed, .requiresUpgrade, .testFailed:
            phase = .idle
        default:
            break
        }
    }

    func resetConnectionTest() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        switch phase {
        case .testing, .testSucceeded, .testFailed:
            phase = .idle
        default:
            break
        }
    }

    func loadFormCredentials(
        for server: Server?,
        onLoaded: @escaping @MainActor (ServerCredentials) -> Void
    ) {
        replaceCredentialLoad(
            unexpectedFailure: { .credentialLoad(message: $0) }
        ) { [weak self] operationID, loader in
            let result = try await loader.loadFormCredentials(for: server)
            guard !Task.isCancelled else { return }
            guard self?.isCurrentCredentialLoad(operationID) == true else { return }

            self?.storedKeys = result.storedKeys
            switch result.savedCredentials {
            case .notRequested:
                self?.finishCredentialLoad(operationID)
            case .loaded(let credentials, let selectedStoredKeyID):
                self?.selectedStoredKeyID = selectedStoredKeyID
                onLoaded(credentials)
                self?.finishCredentialLoad(operationID)
            case .failed(let message):
                self?.failCredentialLoad(operationID, failure: .credentialLoad(message: message))
            }
        }
    }

    func refreshStoredKeys(
        selecting selectedID: UUID,
        onLoaded: @escaping @MainActor (ServerFormStoredKeyLoad) -> Void
    ) {
        replaceCredentialLoad(
            unexpectedFailure: { .storedKeyLoad(message: $0) }
        ) { [weak self] operationID, loader in
            let result = try await loader.loadFormCredentials(for: nil)
            guard !Task.isCancelled else { return }
            guard self?.isCurrentCredentialLoad(operationID) == true else { return }
            self?.storedKeys = result.storedKeys
            guard let entry = result.storedKeys.first(where: { $0.id == selectedID }) else {
                self?.selectedStoredKeyID = nil
                self?.finishCredentialLoad(operationID)
                return
            }
            try await self?.loadStoredKey(
                entry,
                operationID: operationID,
                loader: loader,
                onLoaded: onLoaded
            )
        }
    }

    func selectStoredKey(
        id: UUID,
        onLoaded: @escaping @MainActor (ServerFormStoredKeyLoad) -> Void
    ) {
        guard let entry = storedKeys.first(where: { $0.id == id }) else { return }
        selectedStoredKeyID = id
        replaceCredentialLoad(
            unexpectedFailure: { .storedKeyLoad(message: $0) }
        ) { [weak self] operationID, loader in
            try await self?.loadStoredKey(
                entry,
                operationID: operationID,
                loader: loader,
                onLoaded: onLoaded
            )
        }
    }

    func clearStoredKeySelection() {
        invalidateCredentialLoading()
        selectedStoredKeyID = nil
    }

    func invalidateCredentialLoading() {
        credentialLoadTask?.cancel()
        credentialLoadTask = nil
        if case .loadingCredentials = phase {
            phase = .idle
        }
    }

    func startConnectionTest(
        server: Server,
        credentials: ServerCredentials,
        snapshot: ServerFormModel.ConnectionSnapshot
    ) {
        invalidateCredentialLoading()
        connectionTestTask?.cancel()
        let operationID = makeID()
        phase = .testing(id: operationID, snapshot: snapshot)

        let tester = connectionTester
        connectionTestTask = Task { [weak self] in
            let result = await tester.test(server: server, credentials: credentials)
            guard !Task.isCancelled else { return }
            self?.completeConnectionTest(
                id: operationID,
                snapshot: snapshot,
                result: result
            )
        }
    }

    func rejectHostKeyChallenge() {
        guard let challenge = hostKeyChallenge else { return }
        hostKeys.reject(challenge)
        phase = .idle
    }

    @discardableResult
    func approveHostKeyChallenge() -> Bool {
        guard let challenge = hostKeyChallenge,
              let snapshot = currentTestSnapshot else { return false }
        guard hostKeys.approve(challenge, now: now()) else {
            phase = .testFailed(
                snapshot: snapshot,
                failure: ServerConnectionTestFailure(
                    reason: .hostKeyApprovalExpired,
                    requiresCloudflareOverrides: false,
                    hostKeyChallenge: nil
                )
            )
            return false
        }
        phase = .idle
        return true
    }

    func save(
        mutation: ServerMutation,
        credentials: ServerCredentials,
        hasProAccess: Bool,
        authorize: @escaping @MainActor () async -> Bool,
        onSaved: @escaping @MainActor (Server) -> Void
    ) {
        guard !isSaving else { return }
        saveTask?.cancel()
        let operationID = makeID()
        phase = .saving(id: operationID)
        let useCase = saveUseCase

        saveTask = Task { [weak self] in
            guard await authorize() else {
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                self?.phase = .idle
                return
            }
            do {
                let savedServer = try await useCase.execute(
                    mutation,
                    credentials: credentials,
                    hasProAccess: hasProAccess
                )
                guard !Task.isCancelled else { return }
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                self?.phase = .idle
                onSaved(savedServer)
            } catch let error as VVTermError {
                guard !Task.isCancelled else { return }
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                if case .proRequired = error {
                    self?.phase = .requiresUpgrade
                } else {
                    self?.phase = .failed(.operation(message: error.localizedDescription))
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                self?.phase = .failed(.operation(message: error.localizedDescription))
            }
        }
    }

    func cancel() {
        credentialLoadTask?.cancel()
        credentialLoadTask = nil
        connectionTestTask?.cancel()
        connectionTestTask = nil
        saveTask?.cancel()
        saveTask = nil
        phase = .idle
    }

    private func replaceCredentialLoad(
        unexpectedFailure: @escaping (String) -> ServerFormOperationFailure,
        operation: @escaping @MainActor (
            _ operationID: UUID,
            _ loader: any ServerFormCredentialLoading
        ) async throws -> Void
    ) {
        credentialLoadTask?.cancel()
        let operationID = makeID()
        phase = .loadingCredentials(id: operationID)
        let loader = credentialLoader
        credentialLoadTask = Task { [weak self] in
            do {
                try await operation(operationID, loader)
            } catch is CancellationError {
                return
            } catch {
                self?.failCredentialLoad(
                    operationID,
                    failure: unexpectedFailure(error.localizedDescription)
                )
            }
        }
    }

    private func loadStoredKey(
        _ entry: SSHKeyEntry,
        operationID: UUID,
        loader: any ServerFormCredentialLoading,
        onLoaded: @escaping @MainActor (ServerFormStoredKeyLoad) -> Void
    ) async throws {
        let result = try await loader.loadStoredKey(entry)
        guard !Task.isCancelled else { return }
        guard isCurrentCredentialLoad(operationID) else { return }
        selectedStoredKeyID = result.id
        onLoaded(result)
        finishCredentialLoad(operationID)
    }

    private func finishCredentialLoad(_ id: UUID) {
        guard isCurrentCredentialLoad(id) else { return }
        credentialLoadTask = nil
        phase = .idle
    }

    private func failCredentialLoad(
        _ id: UUID,
        failure: ServerFormOperationFailure
    ) {
        guard isCurrentCredentialLoad(id) else { return }
        credentialLoadTask = nil
        phase = .failed(failure)
    }

    private func isCurrentCredentialLoad(_ id: UUID) -> Bool {
        guard case .loadingCredentials(let currentID) = phase else { return false }
        return currentID == id
    }

    private var currentTestSnapshot: ServerFormModel.ConnectionSnapshot? {
        switch phase {
        case .testing(_, let snapshot), .testSucceeded(let snapshot), .testFailed(let snapshot, _):
            return snapshot
        default:
            return nil
        }
    }

    private func completeConnectionTest(
        id: UUID,
        snapshot: ServerFormModel.ConnectionSnapshot,
        result: ServerConnectionTestResult
    ) {
        guard case .testing(let currentID, let currentSnapshot) = phase,
              currentID == id,
              currentSnapshot == snapshot else { return }
        connectionTestTask = nil
        switch result {
        case .success:
            phase = .testSucceeded(snapshot: snapshot)
        case .failure(let failure):
            phase = .testFailed(snapshot: snapshot, failure: failure)
        case .cancelled:
            phase = .idle
        }
    }

    private func isCurrentSave(_ id: UUID) -> Bool {
        guard case .saving(let currentID) = phase else { return false }
        return currentID == id
    }
}
