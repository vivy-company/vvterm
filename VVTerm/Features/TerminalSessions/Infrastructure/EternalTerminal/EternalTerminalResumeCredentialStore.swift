import ETBootstrap
import ETSession
import Foundation

nonisolated struct EternalTerminalResumeCredentials: Codable, Equatable, Sendable {
    let clientID: String
    let passkey: Data

    init(clientID: String, passkey: Data) throws {
        guard clientID.utf8.count == 16, passkey.count == 32 else {
            throw EternalTerminalResumeCredentialError.invalidCredentials
        }
        self.clientID = clientID
        self.passkey = passkey
    }

    init(_ credentials: ETCredentials) throws {
        try self.init(clientID: credentials.clientID, passkey: credentials.passkey)
    }
}

nonisolated enum EternalTerminalResumeCredentialError: LocalizedError, Sendable {
    case invalidCredentials
    case corruptStoredCredentials
    case secureStorageUnavailable
    case corruptStoredCheckpoint
    case checkpointStorageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            String(localized: "Eternal Terminal returned invalid resume credentials. Update Eternal Terminal on the host and try again.")
        case .corruptStoredCredentials:
            String(localized: "The saved Eternal Terminal session credentials are damaged. Reconnect to start a new session.")
        case .secureStorageUnavailable:
            String(localized: "VVTerm could not access the saved Eternal Terminal session securely. Check Keychain access and try again.")
        case .corruptStoredCheckpoint:
            String(localized: "The saved Eternal Terminal recovery data is damaged. Reconnect to start a new session.")
        case .checkpointStorageUnavailable:
            String(localized: "VVTerm could not save the Eternal Terminal recovery data. Check available device storage and try again.")
        }
    }

    var shouldDeleteStoredCredentials: Bool {
        switch self {
        case .corruptStoredCredentials, .corruptStoredCheckpoint:
            true
        case .invalidCredentials, .secureStorageUnavailable, .checkpointStorageUnavailable:
            false
        }
    }
}

protocol EternalTerminalResumeStoring: Sendable {
    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials?
    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint?
    func hasCheckpoint(for paneId: UUID) -> Bool
    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws
    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws
    func deleteResumeState(for paneId: UUID) throws
}

final class EternalTerminalResumeStore: EternalTerminalResumeStoring, @unchecked Sendable {
    static let shared = EternalTerminalResumeStore()

    private let keychain: KeychainStore
    private let fileManager: FileManager
    private let checkpointDirectory: URL?

    init(
        keychain: KeychainStore = KeychainStore(service: "app.vivy.vvterm.et.resume"),
        fileManager: FileManager = .default,
        checkpointDirectory: URL? = nil
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
        self.checkpointDirectory = checkpointDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("EternalTerminalResume", isDirectory: true)
    }

    func checkpoint(for paneId: UUID) throws -> ETSessionCheckpoint? {
        guard let url = checkpointURL(for: paneId) else {
            throw EternalTerminalResumeCredentialError.checkpointStorageUnavailable
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try PropertyListDecoder().decode(
                ETSessionCheckpoint.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw EternalTerminalResumeCredentialError.corruptStoredCheckpoint
        }
    }

    func hasCheckpoint(for paneId: UUID) -> Bool {
        guard let url = checkpointURL(for: paneId) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func credentials(for paneId: UUID) throws -> EternalTerminalResumeCredentials? {
        let data: Data
        do {
            guard let stored = try keychain.get(
                Self.key(for: paneId),
                scope: .deviceOnly
            ) else { return nil }
            data = stored
        } catch {
            throw EternalTerminalResumeCredentialError.secureStorageUnavailable
        }

        do {
            let decoded = try JSONDecoder().decode(EternalTerminalResumeCredentials.self, from: data)
            return try EternalTerminalResumeCredentials(
                clientID: decoded.clientID,
                passkey: decoded.passkey
            )
        } catch {
            throw EternalTerminalResumeCredentialError.corruptStoredCredentials
        }
    }

    func save(_ credentials: EternalTerminalResumeCredentials, for paneId: UUID) throws {
        do {
            let data = try JSONEncoder().encode(credentials)
            try keychain.set(data, forKey: Self.key(for: paneId), scope: .deviceOnly)
        } catch {
            throw EternalTerminalResumeCredentialError.secureStorageUnavailable
        }
    }

    func save(_ checkpoint: ETSessionCheckpoint, for paneId: UUID) throws {
        guard let checkpointDirectory, let url = checkpointURL(for: paneId) else {
            throw EternalTerminalResumeCredentialError.checkpointStorageUnavailable
        }
        do {
            try fileManager.createDirectory(
                at: checkpointDirectory,
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(checkpoint)
            try data.write(to: url, options: .atomic)
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            throw EternalTerminalResumeCredentialError.checkpointStorageUnavailable
        }
    }

    func deleteResumeState(for paneId: UUID) throws {
        var failed = false
        do {
            try keychain.delete(Self.key(for: paneId), scope: .deviceOnly)
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
            throw EternalTerminalResumeCredentialError.secureStorageUnavailable
        }
    }

    private func checkpointURL(for paneId: UUID) -> URL? {
        checkpointDirectory?.appendingPathComponent(
            "\(paneId.uuidString.lowercased()).checkpoint",
            isDirectory: false
        )
    }

    nonisolated static func key(for paneId: UUID) -> String {
        "terminal.et.resume.\(paneId.uuidString.lowercased())"
    }
}
