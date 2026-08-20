import Foundation
import MoshCore

private struct MoshResumeSecret: Codable, Equatable, Sendable {
    let keyBase64: String
}

private struct MoshResumeCheckpoint: Codable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let transportState: Data
    let createdAtMs: UInt64
    let schemaVersion: UInt16

    init(_ snapshot: MoshSnapshot) {
        host = snapshot.endpoint.host
        port = snapshot.endpoint.port
        transportState = snapshot.transportState
        createdAtMs = snapshot.createdAtMs
        schemaVersion = snapshot.schemaVersion
    }

    func snapshot(keyBase64: String) -> MoshSnapshot {
        MoshSnapshot(
            endpoint: MoshEndpoint(
                host: host,
                port: port,
                keyBase64_22: keyBase64
            ),
            transportState: transportState,
            createdAtMs: createdAtMs,
            schemaVersion: schemaVersion
        )
    }
}

nonisolated enum MoshStoredStateDisposition: Equatable, Sendable {
    case keep
    case discard
}

enum MoshResumeStoreError: LocalizedError {
    case invalidSnapshot
    case corruptStoredSecret
    case secureStorageUnavailable
    case corruptStoredCheckpoint
    case checkpointStorageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            String(localized: "Mosh returned invalid recovery data. Reconnect to start a new session.")
        case .corruptStoredSecret, .corruptStoredCheckpoint:
            String(localized: "The saved Mosh recovery data is damaged. Reconnect to start a new session.")
        case .secureStorageUnavailable:
            String(localized: "VVTerm could not access the saved Mosh session key securely. Check Keychain access and try again.")
        case .checkpointStorageUnavailable:
            String(localized: "VVTerm could not save the Mosh recovery data. Check available device storage and try again.")
        }
    }

    var storedStateDisposition: MoshStoredStateDisposition {
        switch self {
        case .invalidSnapshot, .corruptStoredSecret, .corruptStoredCheckpoint:
            .discard
        case .secureStorageUnavailable, .checkpointStorageUnavailable:
            .keep
        }
    }
}

nonisolated enum MoshResumePolicy {
    static func storedStateDisposition(
        after error: MoshSessionError
    ) -> MoshStoredStateDisposition {
        switch error {
        case .invalidEndpoint, .badSnapshotSchema, .decodeFailure:
            .discard
        case .sessionFailed(let failure):
            switch failure {
            case .protocolViolation, .authenticationFailure:
                .discard
            case .timeout, .retryLimitExceeded, .circuitBreakerTripped,
                 .transportFailure:
                .keep
            }
        case .notStarted, .encodeFailure:
            .keep
        }
    }
}

protocol MoshResumeStoring {
    func snapshot(for paneId: UUID) throws -> MoshSnapshot?
    func hasSnapshot(for paneId: UUID) -> Bool
    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws
    func deleteSnapshot(for paneId: UUID) throws
}

protocol MoshResumeSecretStoring {
    func set(_ data: Data, forKey key: String) throws
    func get(_ key: String) throws -> Data?
    func delete(_ key: String) throws
}

final class DeviceOnlyMoshResumeSecretStore: MoshResumeSecretStoring {
    private let store: KeychainStore

    init(
        store: KeychainStore = KeychainStore(
            service: "app.vivy.vvterm.mosh.resume"
        )
    ) {
        self.store = store
    }

    func set(_ data: Data, forKey key: String) throws {
        try store.set(data, forKey: key, scope: .deviceOnly)
    }

    func get(_ key: String) throws -> Data? {
        try store.get(key, scope: .deviceOnly)
    }

    func delete(_ key: String) throws {
        try store.delete(key, scope: .deviceOnly)
    }
}

final class MoshResumeStore: MoshResumeStoring {
    static let shared = MoshResumeStore()

    private let keychain: any MoshResumeSecretStoring
    private let fileManager: FileManager
    private let checkpointDirectory: URL?

    init(
        keychain: any MoshResumeSecretStoring = DeviceOnlyMoshResumeSecretStore(),
        fileManager: FileManager = .default,
        checkpointDirectory: URL? = nil
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
        self.checkpointDirectory = checkpointDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MoshResume", isDirectory: true)
    }

    func snapshot(for paneId: UUID) throws -> MoshSnapshot? {
        guard let url = checkpointURL(for: paneId) else {
            throw MoshResumeStoreError.checkpointStorageUnavailable
        }
        let checkpointExists = fileManager.fileExists(atPath: url.path)

        let secretData: Data?
        do {
            secretData = try keychain.get(Self.key(for: paneId))
        } catch {
            throw MoshResumeStoreError.secureStorageUnavailable
        }

        guard checkpointExists || secretData != nil else { return nil }
        guard checkpointExists else {
            throw MoshResumeStoreError.corruptStoredCheckpoint
        }
        guard let secretData else {
            throw MoshResumeStoreError.corruptStoredSecret
        }

        let secret: MoshResumeSecret
        do {
            secret = try JSONDecoder().decode(MoshResumeSecret.self, from: secretData)
        } catch {
            throw MoshResumeStoreError.corruptStoredSecret
        }
        guard !secret.keyBase64.isEmpty else {
            throw MoshResumeStoreError.corruptStoredSecret
        }

        let checkpoint: MoshResumeCheckpoint
        do {
            checkpoint = try PropertyListDecoder().decode(
                MoshResumeCheckpoint.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw MoshResumeStoreError.corruptStoredCheckpoint
        }
        guard !checkpoint.host.isEmpty, checkpoint.port > 0 else {
            throw MoshResumeStoreError.corruptStoredCheckpoint
        }
        return checkpoint.snapshot(keyBase64: secret.keyBase64)
    }

    func hasSnapshot(for paneId: UUID) -> Bool {
        guard let url = checkpointURL(for: paneId) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func save(_ snapshot: MoshSnapshot, for paneId: UUID) throws {
        guard !snapshot.endpoint.host.isEmpty,
              snapshot.endpoint.port > 0,
              !snapshot.endpoint.keyBase64_22.isEmpty else {
            throw MoshResumeStoreError.invalidSnapshot
        }
        guard let checkpointDirectory, let url = checkpointURL(for: paneId) else {
            throw MoshResumeStoreError.checkpointStorageUnavailable
        }

        do {
            let secret = MoshResumeSecret(
                keyBase64: snapshot.endpoint.keyBase64_22
            )
            try keychain.set(JSONEncoder().encode(secret), forKey: Self.key(for: paneId))
        } catch {
            throw MoshResumeStoreError.secureStorageUnavailable
        }

        do {
            try fileManager.createDirectory(
                at: checkpointDirectory,
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(MoshResumeCheckpoint(snapshot))
            try data.write(to: url, options: .atomic)
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            throw MoshResumeStoreError.checkpointStorageUnavailable
        }
    }

    func deleteSnapshot(for paneId: UUID) throws {
        var failed = false
        do {
            try keychain.delete(Self.key(for: paneId))
        } catch {
            failed = true
        }
        if let url = checkpointURL(for: paneId), fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failed = true
            }
        }
        if failed {
            throw MoshResumeStoreError.secureStorageUnavailable
        }
    }

    private func checkpointURL(for paneId: UUID) -> URL? {
        checkpointDirectory?.appendingPathComponent(
            "\(paneId.uuidString.lowercased()).checkpoint",
            isDirectory: false
        )
    }

    nonisolated static func key(for paneId: UUID) -> String {
        "terminal.mosh.resume.\(paneId.uuidString.lowercased())"
    }
}
