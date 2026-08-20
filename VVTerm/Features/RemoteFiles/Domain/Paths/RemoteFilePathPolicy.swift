import Foundation

nonisolated enum RemoteFilePathPolicy {
    static func validatedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "Name cannot be empty."))
        }
        return try RemoteFileLeaf(validating: trimmed).value
    }

    static func validatedDirectoryPath(_ value: String, relativeTo currentPath: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "Destination folder cannot be empty."))
        }
        return RemoteFilePath.normalize(trimmed, relativeTo: currentPath)
    }
}
