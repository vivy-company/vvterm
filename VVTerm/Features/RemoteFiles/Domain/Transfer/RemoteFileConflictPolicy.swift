import Foundation

nonisolated enum RemoteFileConflictPolicy: String, Sendable {
    case replaceExisting
    case keepBoth
}

nonisolated struct RemoteFileConflictResolution: Equatable, Sendable {
    let originalName: String
    let resolvedName: String
    let existingEntry: RemoteFileEntry?

    var hasConflict: Bool {
        existingEntry != nil
    }
}
