import ETSession
import Foundation
import Testing
@testable import VVTerm

private final class InMemoryETResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    private var values: [UUID: EternalTerminalResumeCredentials] = [:]
    private var checkpoints: [UUID: ETSessionCheckpoint] = [:]

    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? {
        values[paneId]
    }

    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {
        values[paneId] = credentials
    }

    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? {
        checkpoints[paneId]
    }

    func hasCheckpoint(for paneId: UUID) -> Bool {
        checkpoints[paneId] != nil
    }

    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {
        checkpoints[paneId] = checkpoint
    }

    func deleteResumeState(for paneId: UUID) throws {
        values.removeValue(forKey: paneId)
        checkpoints.removeValue(forKey: paneId)
    }
}

@Suite(.serialized)
@MainActor
struct EternalTerminalResumeCredentialStoreTests {
    private func credentials() throws -> EternalTerminalResumeCredentials {
        try EternalTerminalResumeCredentials(
            clientID: String(repeating: "A", count: 16),
            passkey: Data(repeating: 7, count: 32)
        )
    }

    private func checkpoint() throws -> ETSessionCheckpoint {
        struct Reader: Codable {
            let nonce: Data
            let sequenceNumber: Int64
        }
        struct Writer: Codable {
            let nonce: Data
            let sequenceNumber: Int64
            let serializedBackupPackets: [Data]
        }
        struct Fixture: Codable {
            let reader: Reader
            let writer: Writer
        }

        let fixture = Fixture(
            reader: Reader(nonce: Data(repeating: 0, count: 24), sequenceNumber: 0),
            writer: Writer(
                nonce: Data(repeating: 0, count: 24),
                sequenceNumber: 0,
                serializedBackupPackets: []
            )
        )
        return try JSONDecoder().decode(
            ETSessionCheckpoint.self,
            from: JSONEncoder().encode(fixture)
        )
    }

    @Test
    func credentialsEnforceTheETWireSizes() throws {
        _ = try credentials()

        #expect(throws: EternalTerminalResumeCredentialError.self) {
            try EternalTerminalResumeCredentials(
                clientID: "too-short",
                passkey: Data(repeating: 7, count: 32)
            )
        }
        #expect(throws: EternalTerminalResumeCredentialError.self) {
            try EternalTerminalResumeCredentials(
                clientID: String(repeating: "A", count: 16),
                passkey: Data(repeating: 7, count: 31)
            )
        }
    }

    @Test
    func keychainReferenceIsStableAndContainsNoSecret() throws {
        let paneId = try #require(UUID(uuidString: "50E3AEE5-FD59-4DA0-A07D-67093EFF6AA2"))
        let key = EternalTerminalResumeStore.key(for: paneId)

        #expect(key == "terminal.et.resume.50e3aee5-fd59-4da0-a07d-67093eff6aa2")
        #expect(!key.contains(String(repeating: "A", count: 16)))
    }

    @Test
    func checkpointRoundTripsInProtectedLocalStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vvterm-et-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EternalTerminalResumeStore(checkpointDirectory: directory)
        let paneId = UUID()
        let expected = try checkpoint()

        #expect(!store.hasCheckpoint(for: paneId))
        try store.save(expected, for: paneId)
        #expect(store.hasCheckpoint(for: paneId))
        #expect(try store.checkpoint(for: paneId) == expected)

        let file = try #require(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    func explicitCloseDeletesCredentialsButApplicationTerminationPreservesThem() async throws {
        let manager = TerminalTestComposition.makeManager()

        do {
            let store = InMemoryETResumeStore()
            manager.transportCoordinator.setEternalTerminalResumeStoreForTesting(store)

            let serverId = UUID()
            let firstTab = TerminalTab(serverId: serverId, title: "Close")
            manager.sessionState.install(firstTab, paneState: TerminalPaneState(
                paneId: firstTab.rootPaneId,
                tabId: firstTab.id,
                serverId: serverId
            ), select: true)
            try store.save(credentials(), for: firstTab.rootPaneId)

            manager.closeTab(firstTab)

            #expect(try store.credentials(for: firstTab.rootPaneId) == nil)

            let secondTab = TerminalTab(serverId: serverId, title: "Terminate")
            manager.sessionState.install(secondTab, paneState: TerminalPaneState(
                paneId: secondTab.rootPaneId,
                tabId: secondTab.id,
                serverId: serverId
            ), select: true)
            let savedCredentials = try credentials()
            try store.save(savedCredentials, for: secondTab.rootPaneId)
            let lifecycle = EternalTerminalTmuxResumeContext(
                ownership: .managed,
                markerToken: "safe-marker"
            )
            manager.sessionState.updatePane(secondTab.rootPaneId, persist: true) {
                $0.eternalTerminalTmuxResumeContext = lifecycle
            }

            let snapshot = try manager.sessionState.snapshotDataForTesting()
            let snapshotText = String(decoding: snapshot, as: UTF8.self)
            #expect(!snapshotText.contains(savedCredentials.clientID))
            #expect(!snapshotText.contains(savedCredentials.passkey.base64EncodedString()))

            await manager.beginApplicationTermination().value

            #expect(try store.credentials(for: secondTab.rootPaneId) == savedCredentials)
            #expect(manager.sessionState.tabs(for: serverId).map(\.id) == [secondTab.id])

            manager.sessionState.persistAndRestoreSnapshotForTesting()
            #expect(
                manager.sessionState.paneState(for: secondTab.rootPaneId)?.eternalTerminalTmuxResumeContext
                    == lifecycle
            )
        } catch {
            await manager.resetForTesting()
            throw error
        }
        await manager.resetForTesting()
    }

    @Test
    func onlyPermanentSessionFailuresDiscardResumeCredentials() {
        #expect(EternalTerminalResumePolicy.shouldDiscardCredentials(
            after: EternalTerminalSessionFailure.invalidKey
        ))
        #expect(EternalTerminalResumePolicy.shouldDiscardCredentials(
            after: EternalTerminalSessionFailure.sessionUnrecoverable
        ))
        #expect(EternalTerminalResumePolicy.shouldDiscardCredentials(
            after: EternalTerminalSessionFailure.connectionClosed
        ))
        #expect(!EternalTerminalResumePolicy.shouldDiscardCredentials(
            after: EternalTerminalSessionFailure.transport
        ))
    }

    @Test
    func onlyCorruptStoredCredentialsAreDeletedBeforeRetry() {
        #expect(
            EternalTerminalResumeCredentialError.corruptStoredCredentials
                .shouldDeleteStoredCredentials
        )
        #expect(
            !EternalTerminalResumeCredentialError.secureStorageUnavailable
                .shouldDeleteStoredCredentials
        )
        #expect(
            !EternalTerminalResumeCredentialError.invalidCredentials
                .shouldDeleteStoredCredentials
        )
    }
}
