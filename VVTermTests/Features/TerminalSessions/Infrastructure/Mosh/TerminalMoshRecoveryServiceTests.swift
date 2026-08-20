import Foundation
import MoshCore
import Testing
@testable import VVTerm

private final class TerminalMoshRecoveryStore: MoshResumeStoring {
    var snapshotResult: Result<MoshSnapshot?, Error>
    private(set) var savedSnapshots: [(paneId: UUID, snapshot: MoshSnapshot)] = []
    private(set) var deletedPaneIds: [UUID] = []

    init(snapshotResult: Result<MoshSnapshot?, Error>) {
        self.snapshotResult = snapshotResult
    }

    func snapshot(for paneId: UUID) throws -> MoshSnapshot? {
        try snapshotResult.get()
    }

    func hasSnapshot(for paneId: UUID) -> Bool {
        guard case .success(.some) = snapshotResult else { return false }
        return true
    }

    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws {
        savedSnapshots.append((paneId, snapshot))
    }

    func deleteSnapshot(for paneId: UUID) throws {
        deletedPaneIds.append(paneId)
    }
}

@MainActor
private final class TerminalMoshClientRecorder {
    var restoreError: Error?
    var checkpoint: MoshSnapshot?
    var checkpointOperation: (@MainActor @Sendable () async -> MoshSnapshot?)?
    var backgroundCheckpoint: MoshSnapshot?
    private(set) var resumedShellIds: [UUID] = []

    func operations() -> TerminalMoshClientOperations {
        TerminalMoshClientOperations(
            restoreShell: { [weak self] _, _, _, _ in
                if let error = self?.restoreError {
                    throw error
                }
                throw MoshSessionError.notStarted
            },
            checkpoint: { [weak self] _, _ in
                if let operation = self?.checkpointOperation {
                    return await operation()
                }
                return self?.checkpoint
            },
            prepareForApplicationBackground: { [weak self] _, _ in
                self?.backgroundCheckpoint
            },
            resumeFromApplicationBackground: { [weak self] _, shellId in
                self?.resumedShellIds.append(shellId)
            }
        )
    }
}

@MainActor
struct TerminalMoshRecoveryServiceTests {
    @Test
    func permanentRestoreFailureDiscardsCheckpoint() async {
        let paneId = UUID()
        let store = TerminalMoshRecoveryStore(snapshotResult: .success(Self.snapshot))
        let client = TerminalMoshClientRecorder()
        client.restoreError = MoshSessionError.invalidEndpoint
        let service = TerminalMoshRecoveryService(
            store: store,
            client: client.operations()
        )

        let shell = await service.restoreShell(
            for: paneId,
            using: SSHClient.testing(),
            cols: 80,
            rows: 24
        )

        #expect(shell == nil)
        #expect(store.deletedPaneIds == [paneId])
    }

    @Test
    func transientRestoreFailureKeepsCheckpoint() async {
        let paneId = UUID()
        let store = TerminalMoshRecoveryStore(snapshotResult: .success(Self.snapshot))
        let client = TerminalMoshClientRecorder()
        client.restoreError = MoshSessionError.sessionFailed(
            .transportFailure("offline")
        )
        let service = TerminalMoshRecoveryService(
            store: store,
            client: client.operations()
        )

        let shell = await service.restoreShell(
            for: paneId,
            using: SSHClient.testing(),
            cols: 80,
            rows: 24
        )

        #expect(shell == nil)
        #expect(store.deletedPaneIds.isEmpty)
    }

    @Test
    func corruptStoredCheckpointIsDiscardedBeforeRestore() async {
        let paneId = UUID()
        let store = TerminalMoshRecoveryStore(
            snapshotResult: .failure(MoshResumeStoreError.corruptStoredCheckpoint)
        )
        let service = TerminalMoshRecoveryService(
            store: store,
            client: TerminalMoshClientRecorder().operations()
        )

        let shell = await service.restoreShell(
            for: paneId,
            using: SSHClient.testing(),
            cols: 80,
            rows: 24
        )

        #expect(shell == nil)
        #expect(store.deletedPaneIds == [paneId])
    }

    @Test
    func backgroundLifecyclePersistsEachProducedCheckpoint() async {
        let paneId = UUID()
        let shellId = UUID()
        let store = TerminalMoshRecoveryStore(snapshotResult: .success(nil))
        let client = TerminalMoshClientRecorder()
        client.backgroundCheckpoint = Self.snapshot
        client.checkpoint = Self.resumedSnapshot
        let service = TerminalMoshRecoveryService(
            store: store,
            client: client.operations()
        )
        let sshClient = SSHClient.testing()

        await service.prepareForApplicationBackground(
            for: paneId,
            using: sshClient,
            shellId: shellId,
            isCurrentOwner: { true }
        )
        await service.resumeFromApplicationBackground(
            for: paneId,
            using: sshClient,
            shellId: shellId,
            isCurrentOwner: { true }
        )

        #expect(client.resumedShellIds == [shellId])
        #expect(store.savedSnapshots.map(\.paneId) == [paneId, paneId])
        #expect(store.savedSnapshots.map(\.snapshot) == [Self.snapshot, Self.resumedSnapshot])
    }

    @Test
    func staleCheckpointResultCannotOverwriteCurrentOwnerState() async {
        let paneId = UUID()
        let gate = TerminalMoshCheckpointGate()
        let store = TerminalMoshRecoveryStore(snapshotResult: .success(nil))
        let client = TerminalMoshClientRecorder()
        client.checkpointOperation = {
            await gate.block()
            return Self.snapshot
        }
        let service = TerminalMoshRecoveryService(
            store: store,
            client: client.operations()
        )
        var isCurrentOwner = true

        let task = Task {
            await service.persistCheckpoint(
                for: paneId,
                using: SSHClient.testing(),
                shellId: UUID(),
                isCurrentOwner: { isCurrentOwner }
            )
        }
        await gate.waitUntilBlocked()
        isCurrentOwner = false
        await gate.release()
        await task.value

        #expect(store.savedSnapshots.isEmpty)
    }

    private static let snapshot = MoshSnapshot(
        endpoint: MoshEndpoint(
            host: "example.com",
            port: 60001,
            keyBase64_22: "abcdefghijklmnopqrstuv"
        ),
        transportState: Data([1, 2, 3]),
        createdAtMs: 1
    )

    private static let resumedSnapshot = MoshSnapshot(
        endpoint: MoshEndpoint(
            host: "example.com",
            port: 60001,
            keyBase64_22: "abcdefghijklmnopqrstuv"
        ),
        transportState: Data([4, 5, 6]),
        createdAtMs: 2
    )
}

private actor TerminalMoshCheckpointGate {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
