import Foundation

enum TerminalSnippetSendMode: String, Codable, CaseIterable, Identifiable {
    case insert
    case insertAndEnter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insert:
            return String(localized: "Insert")
        case .insertAndEnter:
            return String(localized: "Insert + Enter")
        }
    }
}

enum TerminalAccessorySystemActionID: String, Codable, CaseIterable, Hashable, Identifiable {
    case escape
    case tab
    case enter
    case backspace
    case delete
    case insert
    case home
    case end
    case pageUp
    case pageDown
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case ctrlC
    case ctrlD
    case ctrlZ
    case ctrlL
    case ctrlA
    case ctrlE
    case ctrlK
    case ctrlU
    case unknown

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var listTitle: String {
        switch self {
        case .escape: return String(localized: "Esc")
        case .tab: return String(localized: "Tab")
        case .enter: return String(localized: "Enter")
        case .backspace: return String(localized: "Backspace")
        case .delete: return String(localized: "Delete")
        case .insert: return String(localized: "Insert")
        case .home: return String(localized: "Home")
        case .end: return String(localized: "End")
        case .pageUp: return String(localized: "Page Up")
        case .pageDown: return String(localized: "Page Down")
        case .arrowUp: return String(localized: "Arrow Up")
        case .arrowDown: return String(localized: "Arrow Down")
        case .arrowLeft: return String(localized: "Arrow Left")
        case .arrowRight: return String(localized: "Arrow Right")
        case .f1: return String(localized: "F1")
        case .f2: return String(localized: "F2")
        case .f3: return String(localized: "F3")
        case .f4: return String(localized: "F4")
        case .f5: return String(localized: "F5")
        case .f6: return String(localized: "F6")
        case .f7: return String(localized: "F7")
        case .f8: return String(localized: "F8")
        case .f9: return String(localized: "F9")
        case .f10: return String(localized: "F10")
        case .f11: return String(localized: "F11")
        case .f12: return String(localized: "F12")
        case .ctrlC: return String(localized: "Ctrl+C")
        case .ctrlD: return String(localized: "Ctrl+D")
        case .ctrlZ: return String(localized: "Ctrl+Z")
        case .ctrlL: return String(localized: "Ctrl+L")
        case .ctrlA: return String(localized: "Ctrl+A")
        case .ctrlE: return String(localized: "Ctrl+E")
        case .ctrlK: return String(localized: "Ctrl+K")
        case .ctrlU: return String(localized: "Ctrl+U")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var toolbarTitle: String {
        switch self {
        case .escape: return String(localized: "Esc")
        case .tab: return String(localized: "Tab")
        case .enter: return String(localized: "Enter")
        case .backspace: return String(localized: "Bksp")
        case .delete: return String(localized: "Del")
        case .insert: return String(localized: "Ins")
        case .home: return String(localized: "Home")
        case .end: return String(localized: "End")
        case .pageUp: return String(localized: "PgUp")
        case .pageDown: return String(localized: "PgDn")
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight: return ""
        case .f1: return String(localized: "F1")
        case .f2: return String(localized: "F2")
        case .f3: return String(localized: "F3")
        case .f4: return String(localized: "F4")
        case .f5: return String(localized: "F5")
        case .f6: return String(localized: "F6")
        case .f7: return String(localized: "F7")
        case .f8: return String(localized: "F8")
        case .f9: return String(localized: "F9")
        case .f10: return String(localized: "F10")
        case .f11: return String(localized: "F11")
        case .f12: return String(localized: "F12")
        case .ctrlC: return String(localized: "^C")
        case .ctrlD: return String(localized: "^D")
        case .ctrlZ: return String(localized: "^Z")
        case .ctrlL: return String(localized: "^L")
        case .ctrlA: return String(localized: "^A")
        case .ctrlE: return String(localized: "^E")
        case .ctrlK: return String(localized: "^K")
        case .ctrlU: return String(localized: "^U")
        case .unknown: return String(localized: "?")
        }
    }

    var iconName: String? {
        switch self {
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        default: return nil
        }
    }

    var isRepeatable: Bool {
        switch self {
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .backspace, .home, .end, .pageUp, .pageDown:
            return true
        default:
            return false
        }
    }
}

enum TerminalAccessoryItemRef: Codable, Hashable {
    case system(TerminalAccessorySystemActionID)
    case snippet(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case systemID
        case snippetID
    }

    private enum Kind: String, Codable {
        case system
        case snippet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .system:
            let id = try container.decode(TerminalAccessorySystemActionID.self, forKey: .systemID)
            self = .system(id)
        case .snippet:
            let id = try container.decode(UUID.self, forKey: .snippetID)
            self = .snippet(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .system(let id):
            try container.encode(Kind.system, forKey: .kind)
            try container.encode(id, forKey: .systemID)
        case .snippet(let id):
            try container.encode(Kind.snippet, forKey: .kind)
            try container.encode(id, forKey: .snippetID)
        }
    }
}

struct TerminalSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var sendMode: TerminalSnippetSendMode
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        sendMode: TerminalSnippetSendMode,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.sendMode = sendMode
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }
}

struct TerminalAccessoryLayout: Codable, Equatable {
    var version: Int
    var activeItems: [TerminalAccessoryItemRef]
    var updatedAt: Date
}

struct TerminalAccessoryProfile: Codable, Equatable {
    var schemaVersion: Int
    var layout: TerminalAccessoryLayout
    var snippets: [TerminalSnippet]
    var updatedAt: Date
    var lastWriterDeviceId: String
}

extension TerminalAccessoryProfile {
    static let schemaVersion = 1
    static let recordType = "UserPreference"
    static let recordName = "terminalAccessory.v1"
    static let defaultsKey = "terminalAccessoryProfileV1"

    static let minActiveItems = 4
    static let maxActiveItems = 28
    static let maxSnippets = 100
    static let maxSnippetTitleLength = 24
    static let maxSnippetContentLength = 2048

    static let defaultActiveItems: [TerminalAccessoryItemRef] = [
        .system(.escape),
        .system(.tab),
        .system(.arrowUp),
        .system(.arrowDown),
        .system(.arrowLeft),
        .system(.arrowRight),
        .system(.backspace),
        .system(.ctrlC),
        .system(.ctrlD),
        .system(.ctrlZ),
        .system(.ctrlL),
        .system(.home),
        .system(.end),
        .system(.pageUp),
        .system(.pageDown)
    ]

    static var defaultValue: TerminalAccessoryProfile {
        TerminalAccessoryProfile(
            schemaVersion: schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: defaultActiveItems,
                updatedAt: .distantPast
            ),
            snippets: [],
            updatedAt: .distantPast,
            lastWriterDeviceId: DeviceIdentity.id
        )
    }

    static var availableSystemActions: [TerminalAccessorySystemActionID] {
        TerminalAccessorySystemActionID.allCases.filter { $0 != .unknown }
    }

    func normalized() -> TerminalAccessoryProfile {
        var snippetsByID: [UUID: TerminalSnippet] = [:]
        for snippet in snippets {
            let normalizedSnippet = snippet.normalized()
            if let existing = snippetsByID[normalizedSnippet.id] {
                if normalizedSnippet.updatedAt > existing.updatedAt {
                    snippetsByID[normalizedSnippet.id] = normalizedSnippet
                }
            } else {
                snippetsByID[normalizedSnippet.id] = normalizedSnippet
            }
        }

        let normalizedSnippets = snippetsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let limitedActiveSnippetIDs = Set(
            normalizedSnippets
                .filter { !$0.isDeleted }
                .prefix(Self.maxSnippets)
                .map(\.id)
        )

        let normalizedAndLimitedSnippets = normalizedSnippets.filter {
            $0.isDeleted || limitedActiveSnippetIDs.contains($0.id)
        }

        let activeSnippetIDs = Set(normalizedAndLimitedSnippets.filter { !$0.isDeleted }.map(\.id))

        var seenItems = Set<TerminalAccessoryItemRef>()
        var normalizedItems: [TerminalAccessoryItemRef] = []

        for item in layout.activeItems {
            switch item {
            case .system(let actionID):
                guard actionID != .unknown else { continue }
            case .snippet(let snippetID):
                guard activeSnippetIDs.contains(snippetID) else { continue }
            }

            guard !seenItems.contains(item) else { continue }
            seenItems.insert(item)
            normalizedItems.append(item)
        }

        if normalizedItems.count > Self.maxActiveItems {
            normalizedItems = Array(normalizedItems.prefix(Self.maxActiveItems))
        }

        if normalizedItems.count < Self.minActiveItems {
            normalizedItems = Self.defaultActiveItems
        }

        return TerminalAccessoryProfile(
            schemaVersion: max(1, schemaVersion),
            layout: TerminalAccessoryLayout(
                version: max(1, layout.version),
                activeItems: normalizedItems,
                updatedAt: layout.updatedAt
            ),
            snippets: Array(normalizedAndLimitedSnippets),
            updatedAt: updatedAt,
            lastWriterDeviceId: lastWriterDeviceId.isEmpty ? DeviceIdentity.id : lastWriterDeviceId
        )
    }

    static func merged(local: TerminalAccessoryProfile, remote: TerminalAccessoryProfile) -> TerminalAccessoryProfile {
        let normalizedLocal = local.normalized()
        let normalizedRemote = remote.normalized()

        let mergedLayout: TerminalAccessoryLayout
        if normalizedLocal.layout.updatedAt >= normalizedRemote.layout.updatedAt {
            mergedLayout = normalizedLocal.layout
        } else {
            mergedLayout = normalizedRemote.layout
        }

        var snippetsByID: [UUID: TerminalSnippet] = [:]
        for snippet in normalizedRemote.snippets {
            snippetsByID[snippet.id] = snippet
        }

        for snippet in normalizedLocal.snippets {
            if let existing = snippetsByID[snippet.id] {
                if snippet.updatedAt >= existing.updatedAt {
                    snippetsByID[snippet.id] = snippet
                }
            } else {
                snippetsByID[snippet.id] = snippet
            }
        }

        let mergedSnippets = snippetsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let mergedUpdatedAt = max(
            normalizedLocal.updatedAt,
            normalizedRemote.updatedAt,
            mergedLayout.updatedAt,
            mergedSnippets.first?.updatedAt ?? .distantPast
        )

        let writerDeviceID: String
        if mergedUpdatedAt == normalizedLocal.updatedAt {
            writerDeviceID = normalizedLocal.lastWriterDeviceId
        } else if mergedUpdatedAt == normalizedRemote.updatedAt {
            writerDeviceID = normalizedRemote.lastWriterDeviceId
        } else if mergedLayout.updatedAt == normalizedLocal.layout.updatedAt {
            writerDeviceID = normalizedLocal.lastWriterDeviceId
        } else {
            writerDeviceID = normalizedRemote.lastWriterDeviceId
        }

        return TerminalAccessoryProfile(
            schemaVersion: max(normalizedLocal.schemaVersion, normalizedRemote.schemaVersion, Self.schemaVersion),
            layout: mergedLayout,
            snippets: Array(mergedSnippets),
            updatedAt: mergedUpdatedAt,
            lastWriterDeviceId: writerDeviceID
        )
        .normalized()
    }
}

private extension TerminalSnippet {
    func normalized() -> TerminalSnippet {
        let sanitizedTitle: String
        let sanitizedContent: String
        if isDeleted {
            sanitizedTitle = ""
            sanitizedContent = ""
        } else {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            sanitizedTitle = String(trimmedTitle.prefix(TerminalAccessoryProfile.maxSnippetTitleLength))
            sanitizedContent = String(content.prefix(TerminalAccessoryProfile.maxSnippetContentLength))
        }

        return TerminalSnippet(
            id: id,
            title: sanitizedTitle,
            content: sanitizedContent,
            sendMode: sendMode,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
