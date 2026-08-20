import CryptoKit
import Foundation

nonisolated enum MLXModelStorageLayout {
    static func currentDirectory(
        root: URL,
        kind: MLXModelKind,
        modelID: String
    ) -> URL {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "unknown-model" : trimmed
        let name = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root
            .appendingPathComponent(kind.folderName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}

nonisolated enum MLXModelStorageInstaller {
    static func install(
        stagingDirectory: URL,
        finalDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let backupDirectory = finalDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(finalDirectory.lastPathComponent)-backup", isDirectory: true)

        if fileManager.fileExists(atPath: backupDirectory.path) {
            try fileManager.removeItem(at: backupDirectory)
        }
        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.moveItem(at: finalDirectory, to: backupDirectory)
        }

        do {
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            if fileManager.fileExists(atPath: backupDirectory.path) {
                try? fileManager.removeItem(at: backupDirectory)
            }
        } catch {
            if fileManager.fileExists(atPath: backupDirectory.path),
               !fileManager.fileExists(atPath: finalDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: finalDirectory)
            }
            throw error
        }
    }
}
