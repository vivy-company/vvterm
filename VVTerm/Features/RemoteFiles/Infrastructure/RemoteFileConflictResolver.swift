import Foundation

struct RemoteFileConflictResolver {
    nonisolated init() {}

    func resolveName(
        for originalName: String,
        in remoteDirectoryPath: String,
        policy: RemoteFileConflictPolicy,
        using service: any RemoteFileService,
        reservedNames: inout Set<String>
    ) async throws -> RemoteFileConflictResolution {
        let normalizedDirectoryPath = RemoteFilePath.normalize(remoteDirectoryPath)
        let originalLeaf = try RemoteFileLeaf(validating: originalName)
        let remotePath = RemoteFilePath.appending(originalLeaf, to: normalizedDirectoryPath)

        do {
            let existingEntry = try await service.lstat(at: remotePath)
            let resolvedName: String

            switch policy {
            case .replaceExisting:
                resolvedName = originalName
            case .keepBoth:
                resolvedName = try await uniqueName(
                    for: originalName,
                    in: normalizedDirectoryPath,
                    using: service,
                    reservedNames: &reservedNames
                )
            }

            return RemoteFileConflictResolution(
                originalName: originalName,
                resolvedName: resolvedName,
                existingEntry: existingEntry
            )
        } catch let error as RemoteFileBrowserError {
            if error == .pathNotFound {
                reservedNames.insert(originalName)
                return RemoteFileConflictResolution(
                    originalName: originalName,
                    resolvedName: originalName,
                    existingEntry: nil
                )
            }
            throw error
        }
    }

    private func uniqueName(
        for originalName: String,
        in remoteDirectoryPath: String,
        using service: any RemoteFileService,
        reservedNames: inout Set<String>
    ) async throws -> String {
        let fileURL = URL(fileURLWithPath: originalName)
        let pathExtension = fileURL.pathExtension
        let baseName = pathExtension.isEmpty
            ? originalName
            : fileURL.deletingPathExtension().lastPathComponent

        for index in 2...10_000 {
            let candidateName: String
            if pathExtension.isEmpty {
                candidateName = "\(baseName) \(index)"
            } else {
                candidateName = "\(baseName) \(index).\(pathExtension)"
            }

            guard !reservedNames.contains(candidateName) else { continue }

            let candidateLeaf = try RemoteFileLeaf(validating: candidateName)
            let candidatePath = RemoteFilePath.appending(candidateLeaf, to: remoteDirectoryPath)
            do {
                _ = try await service.lstat(at: candidatePath)
                continue
            } catch let error as RemoteFileBrowserError {
                if error == .pathNotFound {
                    reservedNames.insert(candidateName)
                    return candidateName
                }
                throw error
            }
        }

        throw RemoteFileBrowserError.failed(
            String(localized: "Unable to generate a unique name for the uploaded item.")
        )
    }
}
