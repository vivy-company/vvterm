import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class SSHKeySettingsRepositorySpy: SSHKeySettingsRepository {
    var loadedKeys: [SSHKeyEntry] = []
    var importedRequests: [ImportedSSHKeyRequest] = []
    var generatedRequests: [GeneratedSSHKeyRequest] = []
    var deletedIDs: [UUID] = []
    var importFailure: SSHKeySettingsFailure?
    var generateFailure: SSHKeySettingsFailure?
    var deleteFailure: SSHKeySettingsFailure?

    func loadKeys() -> [SSHKeyEntry] {
        loadedKeys
    }

    func storeImportedKey(_ request: ImportedSSHKeyRequest) throws(SSHKeySettingsFailure) -> SSHKeyEntry {
        importedRequests.append(request)
        if let importFailure { throw importFailure }
        let entry = Self.entry(name: request.name)
        loadedKeys.append(entry)
        return entry
    }

    func generateAndStoreKey(_ request: GeneratedSSHKeyRequest) throws(SSHKeySettingsFailure) -> SSHKeyEntry {
        generatedRequests.append(request)
        if let generateFailure { throw generateFailure }
        let entry = Self.entry(name: request.name, keyType: request.keyType)
        loadedKeys.append(entry)
        return entry
    }

    func deleteKey(id: UUID) throws(SSHKeySettingsFailure) {
        deletedIDs.append(id)
        if let deleteFailure { throw deleteFailure }
        loadedKeys.removeAll { $0.id == id }
    }

    static func entry(
        id: UUID = UUID(),
        name: String,
        keyType: SSHKeyType? = nil
    ) -> SSHKeyEntry {
        SSHKeyEntry(
            id: id,
            name: name,
            hasPassphrase: false,
            createdAt: Date(timeIntervalSince1970: 42),
            keyType: keyType,
            publicKey: nil
        )
    }
}

@MainActor
struct SSHKeySettingsCoordinatorTests {
    @Test
    func loadPublishesRepositoryKeys() {
        let repository = SSHKeySettingsRepositorySpy()
        repository.loadedKeys = [.init(
            id: UUID(),
            name: "Existing",
            hasPassphrase: true,
            createdAt: Date(timeIntervalSince1970: 1),
            keyType: .ed25519,
            publicKey: "ssh-ed25519 key"
        )]
        let coordinator = SSHKeySettingsCoordinator(repository: repository)

        coordinator.loadKeys()

        #expect(coordinator.keys == repository.loadedKeys)
    }

    @Test
    func importStoresExactRequestAndReloadsPublishedKeys() {
        let repository = SSHKeySettingsRepositorySpy()
        let coordinator = SSHKeySettingsCoordinator(repository: repository)
        let privateKey = Data("private".utf8)

        let entry = coordinator.storeImportedKey(
            name: "Imported",
            privateKey: privateKey,
            passphrase: "secret"
        )

        #expect(entry?.name == "Imported")
        #expect(repository.importedRequests == [ImportedSSHKeyRequest(
            name: "Imported",
            privateKey: privateKey,
            passphrase: "secret"
        )])
        #expect(coordinator.keys == repository.loadedKeys)
        #expect(coordinator.operationFailures.isEmpty)
    }

    @Test
    func generationPreservesCommentPolicyAndReloadsPublishedKeys() {
        let repository = SSHKeySettingsRepositorySpy()
        let coordinator = SSHKeySettingsCoordinator(repository: repository)

        let entry = coordinator.generateAndStoreKey(
            name: "Work Key",
            passphrase: nil,
            keyType: .rsa4096
        )

        #expect(entry?.keyType == .rsa4096)
        #expect(repository.generatedRequests == [GeneratedSSHKeyRequest(
            name: "Work Key",
            comment: "Work_Key",
            passphrase: nil,
            keyType: .rsa4096
        )])
        #expect(coordinator.keys == repository.loadedKeys)
    }

    @Test
    func deleteReloadsKeysAndPublishesClosedFailureOnError() {
        let repository = SSHKeySettingsRepositorySpy()
        let key = SSHKeySettingsRepositorySpy.entry(name: "Delete")
        repository.loadedKeys = [key]
        let coordinator = SSHKeySettingsCoordinator(repository: repository)
        coordinator.loadKeys()

        repository.deleteFailure = .keychain(status: -25_300)
        coordinator.deleteKey(key)
        #expect(coordinator.failure(for: .deleteKey) == .keychain(status: -25_300))
        #expect(coordinator.keys == [key])

        repository.deleteFailure = nil
        coordinator.deleteKey(key)
        #expect(coordinator.failure(for: .deleteKey) == nil)
        #expect(coordinator.keys.isEmpty)
        #expect(repository.deletedIDs == [key.id, key.id])
    }

    @Test
    func importAndGenerationFailuresRemainDistinct() {
        let repository = SSHKeySettingsRepositorySpy()
        let coordinator = SSHKeySettingsCoordinator(repository: repository)
        repository.importFailure = .keychainEncodingFailed

        #expect(coordinator.storeImportedKey(
            name: "Import",
            privateKey: Data(),
            passphrase: nil
        ) == nil)
        #expect(coordinator.failure(for: .importKey) == .keychainEncodingFailed)

        repository.generateFailure = .keyGenerationFailed
        #expect(coordinator.generateAndStoreKey(
            name: "Generate",
            passphrase: nil,
            keyType: .ed25519
        ) == nil)
        #expect(coordinator.failure(for: .generateKey) == .keyGenerationFailed)
        #expect(coordinator.failure(for: .importKey) == .keychainEncodingFailed)
    }

    @Test
    func presentationMapsEverySemanticFailureToExactDetails() {
        let mappings: [(SSHKeySettingsFailure, String)] = [
            (.keychain(status: -25_300), "Keychain error: -25300"),
            (.keychainEncodingFailed, "Failed to encode data for Keychain"),
            (.keychainDecodingFailed, "Failed to decode data from Keychain"),
            (.keychainItemNotFound, "Item not found in Keychain"),
            (.credentialServerMismatch, "Credentials do not belong to this server"),
            (
                .keychainCopyVerificationFailed,
                "VVTerm could not verify the copied Keychain item"
            ),
            (.keyGenerationFailed, "Failed to generate SSH key"),
            (.keyEncodingFailed, "Failed to encode key data"),
            (.rsaExportFailed, "Failed to export RSA key"),
            (.invalidKeyData, "Invalid key data"),
            (.unavailable, "The SSH key operation could not be completed.")
        ]

        for (failure, expected) in mappings {
            #expect(SSHKeySettingsFailurePresentation.details(for: failure) == expected)
        }
    }

    @Test
    func presentationPreservesExactOperationCopy() {
        let failure = SSHKeySettingsFailure.invalidKeyData

        #expect(SSHKeySettingsFailurePresentation.message(
            for: .importKey,
            failure: failure
        ) == "Failed to save key: Invalid key data")
        #expect(SSHKeySettingsFailurePresentation.message(
            for: .generateKey,
            failure: failure
        ) == "Failed to generate key: Invalid key data")
        #expect(SSHKeySettingsFailurePresentation.message(
            for: .deleteKey,
            failure: failure
        ) == "Failed to delete key: Invalid key data")
    }
}
