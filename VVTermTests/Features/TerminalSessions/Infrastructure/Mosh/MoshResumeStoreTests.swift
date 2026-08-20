import Foundation
import MoshCore
import Testing
@testable import VVTerm

private final class InMemoryMoshResumeSecretStore: MoshResumeSecretStoring {
    private var values: [String: Data] = [:]

    func set(_ data: Data, forKey key: String) throws {
        values[key] = data
    }

    func get(_ key: String) throws -> Data? {
        values[key]
    }

    func delete(_ key: String) throws {
        values.removeValue(forKey: key)
    }
}

@Suite(.serialized)
@MainActor
struct MoshResumeStoreTests {
    private func snapshot() -> MoshSnapshot {
        MoshSnapshot(
            endpoint: MoshEndpoint(
                host: "example.com",
                port: 60001,
                keyBase64_22: "abcdefghijklmnopqrstuv"
            ),
            transportState: Data("protocol-state".utf8),
            createdAtMs: 42,
            schemaVersion: 2
        )
    }

    @Test
    func snapshotSeparatesSecretFromProtectedCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vvterm-mosh-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretStore = InMemoryMoshResumeSecretStore()
        let store = MoshResumeStore(
            keychain: secretStore,
            checkpointDirectory: directory
        )
        let paneId = UUID()
        let expected = snapshot()

        #expect(!store.hasSnapshot(for: paneId))
        try store.save(expected, for: paneId)
        #expect(store.hasSnapshot(for: paneId))
        #expect(try store.snapshot(for: paneId) == expected)

        let file = try #require(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first)
        let checkpointData = try Data(contentsOf: file)
        #expect(!checkpointData.contains(Data(expected.endpoint.keyBase64_22.utf8)))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    func keychainReferenceIsStableAndContainsNoSecret() throws {
        let paneId = try #require(
            UUID(uuidString: "50E3AEE5-FD59-4DA0-A07D-67093EFF6AA2")
        )
        let key = MoshResumeStore.key(for: paneId)

        #expect(key == "terminal.mosh.resume.50e3aee5-fd59-4da0-a07d-67093eff6aa2")
        #expect(!key.contains(snapshot().endpoint.keyBase64_22))
    }

    @Test
    func onlyPermanentlyInvalidSnapshotsAreDiscarded() {
        #expect(MoshResumePolicy.storedStateDisposition(after: .invalidEndpoint) == .discard)
        #expect(MoshResumePolicy.storedStateDisposition(after: .badSnapshotSchema(99)) == .discard)
        #expect(MoshResumePolicy.storedStateDisposition(after: .decodeFailure) == .discard)
        #expect(MoshResumePolicy.storedStateDisposition(
            after: .sessionFailed(.authenticationFailure("invalid key"))
        ) == .discard)
        #expect(MoshResumePolicy.storedStateDisposition(
            after: .sessionFailed(.transportFailure("offline"))
        ) == .keep)
        #expect(MoshResumePolicy.storedStateDisposition(after: .notStarted) == .keep)
    }
}
