import Foundation

nonisolated enum MLXModelIDResolution: Equatable, Sendable {
    case supported(String)
    case migrated(from: String, to: String)
    case unsupported(String)

    var modelID: String {
        switch self {
        case .supported(let modelID), .unsupported(let modelID):
            return modelID
        case .migrated(_, let modelID):
            return modelID
        }
    }
}

/// Temporary, one-time upgrade rules. Remove this type and its tests after
/// supported releases have migrated their saved IDs and legacy directories.
nonisolated enum MLXModelLegacyMigration {
    static func resolveModelID(_ modelID: String, kind: MLXModelKind) -> MLXModelIDResolution {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? MLXModelCatalog.defaultModelID(for: kind) : trimmed
        if MLXModelCatalog.option(for: candidate, kind: kind) != nil {
            return .supported(candidate)
        }
        if let migrated = modelIDMigrations[kind]?[candidate] {
            return .migrated(from: candidate, to: migrated)
        }
        return .unsupported(candidate)
    }

    static func sourceModelIDs(for modelID: String, kind: MLXModelKind) -> [String] {
        var ids = [modelID]
        for (legacyID, targetID) in modelIDMigrations[kind] ?? [:]
            where targetID == modelID {
            ids.append(legacyID)
        }
        return Array(Set(ids)).sorted()
    }

    private static let modelIDMigrations: [MLXModelKind: [String: String]] = [
        .whisper: [
            "mlx-community/whisper-tiny": "mlx-community/whisper-tiny-mlx",
            "mlx-community/whisper-tiny.en": "mlx-community/whisper-tiny.en-mlx",
            "mlx-community/whisper-base": "mlx-community/whisper-base-mlx",
            "mlx-community/whisper-small": "mlx-community/whisper-small-mlx",
            "mlx-community/whisper-medium": "mlx-community/whisper-medium-mlx",
            "mlx-community/whisper-medium-mlx-8bit": "mlx-community/whisper-medium-mlx",
            "mlx-community/whisper-medium-mlx-q4": "mlx-community/whisper-medium-mlx",
            "mlx-community/whisper-medium-mlx-fp32": "mlx-community/whisper-medium-mlx",
            "mlx-community/whisper-large-v3": "mlx-community/whisper-large-v3-mlx"
        ]
    ]
}

nonisolated enum MLXLegacyModelAdoptionResult: Equatable, Sendable {
    case noLegacyDownload
    case adopted
    case updateRequired
}

extension MLXModelStorageLayout {
    nonisolated static func legacyDirectories(
        root: URL,
        kind: MLXModelKind,
        modelID: String
    ) -> [URL] {
        MLXModelLegacyMigration.sourceModelIDs(for: modelID, kind: kind).compactMap { legacyID in
            guard let name = legacyDirectoryName(for: legacyID) else { return nil }
            return root
                .appendingPathComponent(kind.folderName, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        }
    }

    nonisolated private static func legacyDirectoryName(for modelID: String) -> String? {
        let name = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "--")
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return name
    }
}

nonisolated enum MLXModelLegacyAdopter {
    static func adoptIfPossible(
        root: URL,
        kind: MLXModelKind,
        modelID: String,
        trustedManifest: MLXModelDownloadManifest? = nil,
        fileManager: FileManager = .default
    ) -> MLXLegacyModelAdoptionResult {
        guard let manifest = trustedManifest ?? MLXModelCatalog.downloadManifest(for: modelID, kind: kind) else {
            let hasLegacy = MLXModelStorageLayout
                .legacyDirectories(root: root, kind: kind, modelID: modelID)
                .contains { fileManager.fileExists(atPath: $0.path) }
            return hasLegacy ? .updateRequired : .noLegacyDownload
        }

        let finalDirectory = MLXModelStorageLayout.currentDirectory(
            root: root,
            kind: kind,
            modelID: modelID
        )
        guard !fileManager.fileExists(atPath: finalDirectory.path) else {
            return .updateRequired
        }

        var foundLegacyDirectory = false
        for sourceDirectory in MLXModelStorageLayout.legacyDirectories(
            root: root,
            kind: kind,
            modelID: modelID
        ) where fileManager.fileExists(atPath: sourceDirectory.path) {
            foundLegacyDirectory = true
            guard validates(directory: sourceDirectory, manifest: manifest) else { continue }
            if adopt(
                sourceDirectory: sourceDirectory,
                finalDirectory: finalDirectory,
                manifest: manifest,
                fileManager: fileManager
            ) {
                return .adopted
            }
        }
        return foundLegacyDirectory ? .updateRequired : .noLegacyDownload
    }

    static func removeIncompatibleDownloads(
        root: URL,
        kind: MLXModelKind,
        modelID: String,
        fileManager: FileManager = .default
    ) throws {
        for directory in MLXModelStorageLayout.legacyDirectories(
            root: root,
            kind: kind,
            modelID: modelID
        ) where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }

        let current = MLXModelStorageLayout.currentDirectory(root: root, kind: kind, modelID: modelID)
        if fileManager.fileExists(atPath: current.path),
           !MLXModelManager.isModelAvailable(kind: kind, modelId: modelID, modelsRoot: root) {
            try fileManager.removeItem(at: current)
        }
    }

    private static func adopt(
        sourceDirectory: URL,
        finalDirectory: URL,
        manifest: MLXModelDownloadManifest,
        fileManager: FileManager
    ) -> Bool {
        let parent = finalDirectory.deletingLastPathComponent()
        let stagingDirectory = parent.appendingPathComponent(
            ".\(finalDirectory.lastPathComponent)-\(UUID().uuidString).adopting",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceDirectory, to: stagingDirectory)
            guard validates(directory: stagingDirectory, manifest: manifest) else {
                throw MLXModelDownloadError.checksumMismatch
            }
            try Data(manifest.revision.utf8).write(
                to: stagingDirectory.appendingPathComponent(MLXModelDownloadManifest.markerFilename),
                options: .atomic
            )
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            guard validatesInstalled(directory: finalDirectory, manifest: manifest) else {
                try? fileManager.removeItem(at: finalDirectory)
                return false
            }
            try? fileManager.removeItem(at: sourceDirectory)
            return true
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            return false
        }
    }

    private static func validatesInstalled(
        directory: URL,
        manifest: MLXModelDownloadManifest
    ) -> Bool {
        let marker = directory.appendingPathComponent(MLXModelDownloadManifest.markerFilename)
        guard let data = try? Data(contentsOf: marker),
              String(data: data, encoding: .utf8) == manifest.revision else {
            return false
        }
        return validates(directory: directory, manifest: manifest)
    }

    private static func validates(
        directory: URL,
        manifest: MLXModelDownloadManifest
    ) -> Bool {
        for file in manifest.files {
            do {
                try MLXModelFileVerifier.verify(
                    directory.appendingPathComponent(file.localFilename),
                    expectedBytes: file.expectedBytes,
                    sha256: file.sha256
                )
            } catch {
                return false
            }
        }
        return true
    }
}
