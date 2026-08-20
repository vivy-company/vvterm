import Foundation

nonisolated enum RemoteFileType: String, Codable, CaseIterable, Sendable {
    case file
    case directory
    case symlink
    case other

    var displayName: String {
        switch self {
        case .file:
            return String(localized: "File")
        case .directory:
            return String(localized: "Directory")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Other")
        }
    }
}
