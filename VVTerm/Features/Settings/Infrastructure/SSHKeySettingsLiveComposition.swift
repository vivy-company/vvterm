import Foundation

@MainActor
private final class KeychainSSHKeySettingsRepository: SSHKeySettingsRepository {
    private let keychain: KeychainManager

    init(keychain: KeychainManager) {
        self.keychain = keychain
    }

    func loadKeys() -> [SSHKeyEntry] {
        keychain.getStoredSSHKeys()
    }

    func storeImportedKey(_ request: ImportedSSHKeyRequest) throws(SSHKeySettingsFailure) -> SSHKeyEntry {
        do {
            return try keychain.storeSSHKeyEntry(
                name: request.name,
                privateKey: request.privateKey,
                passphrase: request.passphrase
            )
        } catch {
            throw Self.failure(for: error)
        }
    }

    func generateAndStoreKey(_ request: GeneratedSSHKeyRequest) throws(SSHKeySettingsFailure) -> SSHKeyEntry {
        do {
            let key = try SSHKeyGenerator.generate(
                type: request.keyType,
                comment: request.comment
            )
            return try keychain.storeSSHKeyEntry(
                name: request.name,
                privateKey: key.privateKey,
                passphrase: request.passphrase,
                keyType: key.keyType,
                publicKey: key.publicKey
            )
        } catch {
            throw Self.failure(for: error)
        }
    }

    func deleteKey(id: UUID) throws(SSHKeySettingsFailure) {
        do {
            try keychain.deleteStoredSSHKey(id)
        } catch {
            throw Self.failure(for: error)
        }
    }

    private static func failure(for error: Error) -> SSHKeySettingsFailure {
        if let keychainError = error as? KeychainError {
            return switch keychainError {
            case .unhandled(let status): .keychain(status: status)
            case .encodingFailed: .keychainEncodingFailed
            case .decodingFailed: .keychainDecodingFailed
            case .itemNotFound: .keychainItemNotFound
            case .credentialServerMismatch: .credentialServerMismatch
            case .copyVerificationFailed: .keychainCopyVerificationFailed
            }
        }
        if let generationError = error as? SSHKeyGeneratorError {
            return switch generationError {
            case .keyGenerationFailed: .keyGenerationFailed
            case .encodingFailed: .keyEncodingFailed
            case .rsaExportFailed: .rsaExportFailed
            case .invalidKeyData: .invalidKeyData
            }
        }
        return .unavailable
    }
}

@MainActor
enum SSHKeySettingsLiveComposition {
    static func makeCoordinator(keychain: KeychainManager) -> SSHKeySettingsCoordinator {
        SSHKeySettingsCoordinator(
            repository: KeychainSSHKeySettingsRepository(keychain: keychain)
        )
    }
}

#if DEBUG
@MainActor
private final class PreviewSSHKeySettingsRepository: SSHKeySettingsRepository {
    func loadKeys() -> [SSHKeyEntry] { [] }

    func storeImportedKey(_ request: ImportedSSHKeyRequest) throws(SSHKeySettingsFailure) -> SSHKeyEntry {
        throw .unavailable
    }

    func generateAndStoreKey(_ request: GeneratedSSHKeyRequest) throws(SSHKeySettingsFailure) -> SSHKeyEntry {
        throw .unavailable
    }

    func deleteKey(id: UUID) throws(SSHKeySettingsFailure) {
        throw .unavailable
    }
}

extension SSHKeySettingsCoordinator {
    static var preview: SSHKeySettingsCoordinator {
        SSHKeySettingsCoordinator(repository: PreviewSSHKeySettingsRepository())
    }
}
#endif
