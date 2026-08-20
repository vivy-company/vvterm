import Foundation

nonisolated enum RemoteFileSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case modifiedAt
    case size

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            return String(localized: "Name")
        case .modifiedAt:
            return String(localized: "Date Modified")
        case .size:
            return String(localized: "Size")
        }
    }

    var defaultDirection: RemoteFileSortDirection {
        switch self {
        case .name:
            return .ascending
        case .modifiedAt, .size:
            return .descending
        }
    }
}

nonisolated enum RemoteFileSortDirection: String, Codable, Sendable {
    case ascending
    case descending

    init(sortOrder: SortOrder) {
        switch sortOrder {
        case .forward:
            self = .ascending
        case .reverse:
            self = .descending
        }
    }

    var sortOrder: SortOrder {
        switch self {
        case .ascending:
            return .forward
        case .descending:
            return .reverse
        }
    }
}

nonisolated extension Array where Element == RemoteFileEntry {
    func sortedForBrowser(using sort: RemoteFileSort, direction: RemoteFileSortDirection) -> [RemoteFileEntry] {
        sorted { lhs, rhs in
            let lhsDirectoryRank = lhs.type == .directory ? 0 : 1
            let rhsDirectoryRank = rhs.type == .directory ? 0 : 1
            if lhsDirectoryRank != rhsDirectoryRank {
                return lhsDirectoryRank < rhsDirectoryRank
            }

            switch sort {
            case .name:
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison != .orderedSame {
                    return direction == .ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            case .modifiedAt:
                let lhsDate = lhs.modifiedAt ?? .distantPast
                let rhsDate = rhs.modifiedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return direction == .ascending ? lhsDate < rhsDate : lhsDate > rhsDate
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                let lhsSize = lhs.size ?? 0
                let rhsSize = rhs.size ?? 0
                if lhsSize != rhsSize {
                    return direction == .ascending ? lhsSize < rhsSize : lhsSize > rhsSize
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
