import Foundation

nonisolated struct RemoteFileLeaf: Hashable, Sendable {
    let value: String

    init(validating value: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !Self.isWindowsAbsolutePath(value) else {
            throw RemoteFileBrowserError.invalidEntryName
        }
        self.value = value
    }

    private static func isWindowsAbsolutePath(_ value: String) -> Bool {
        guard value.count >= 2 else { return false }
        let prefix = value.prefix(2)
        return prefix.first?.isLetter == true && prefix.last == ":"
    }
}
