import Foundation

nonisolated enum TerminalSnippetSendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case insert
    case insertAndEnter

    var id: String { rawValue }
}

nonisolated enum TerminalAccessoryCustomActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case command
    case shortcut

    var id: String { rawValue }
}

nonisolated struct TerminalAccessoryShortcutModifiers: Codable, Equatable, Hashable, Sendable {
    var control: Bool = false
    var alternate: Bool = false
    var command: Bool = false
    var shift: Bool = false

    private enum CodingKeys: String, CodingKey {
        case control
        case alternate
        case command
        case shift
    }

    static let none = TerminalAccessoryShortcutModifiers()

    init(
        control: Bool = false,
        alternate: Bool = false,
        command: Bool = false,
        shift: Bool = false
    ) {
        self.control = control
        self.alternate = alternate
        self.command = command
        self.shift = shift
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decodeIfPresent(Bool.self, forKey: .control) ?? false
        alternate = try container.decodeIfPresent(Bool.self, forKey: .alternate) ?? false
        command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? false
        shift = try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(control, forKey: .control)
        try container.encode(alternate, forKey: .alternate)
        try container.encode(command, forKey: .command)
        try container.encode(shift, forKey: .shift)
    }

}

nonisolated enum TerminalAccessoryShortcutKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case a
    case b
    case c
    case d
    case e
    case f
    case g
    case h
    case i
    case j
    case k
    case l
    case m
    case n
    case o
    case p
    case q
    case r
    case s
    case t
    case u
    case v
    case w
    case x
    case y
    case z
    case digit0
    case digit1
    case digit2
    case digit3
    case digit4
    case digit5
    case digit6
    case digit7
    case digit8
    case digit9
    case backquote
    case minus
    case equal
    case bracketLeft
    case bracketRight
    case backslash
    case semicolon
    case quote
    case comma
    case period
    case slash
    case space
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

    var id: String { rawValue }

    var unshiftedText: String? {
        switch self {
        case .a: return "a"
        case .b: return "b"
        case .c: return "c"
        case .d: return "d"
        case .e: return "e"
        case .f: return "f"
        case .g: return "g"
        case .h: return "h"
        case .i: return "i"
        case .j: return "j"
        case .k: return "k"
        case .l: return "l"
        case .m: return "m"
        case .n: return "n"
        case .o: return "o"
        case .p: return "p"
        case .q: return "q"
        case .r: return "r"
        case .s: return "s"
        case .t: return "t"
        case .u: return "u"
        case .v: return "v"
        case .w: return "w"
        case .x: return "x"
        case .y: return "y"
        case .z: return "z"
        case .digit0: return "0"
        case .digit1: return "1"
        case .digit2: return "2"
        case .digit3: return "3"
        case .digit4: return "4"
        case .digit5: return "5"
        case .digit6: return "6"
        case .digit7: return "7"
        case .digit8: return "8"
        case .digit9: return "9"
        case .backquote: return "`"
        case .minus: return "-"
        case .equal: return "="
        case .bracketLeft: return "["
        case .bracketRight: return "]"
        case .backslash: return "\\"
        case .semicolon: return ";"
        case .quote: return "'"
        case .comma: return ","
        case .period: return "."
        case .slash: return "/"
        case .space: return " "
        default: return nil
        }
    }

    var shiftedText: String? {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        case .digit0: return ")"
        case .digit1: return "!"
        case .digit2: return "@"
        case .digit3: return "#"
        case .digit4: return "$"
        case .digit5: return "%"
        case .digit6: return "^"
        case .digit7: return "&"
        case .digit8: return "*"
        case .digit9: return "("
        case .backquote: return "~"
        case .minus: return "_"
        case .equal: return "+"
        case .bracketLeft: return "{"
        case .bracketRight: return "}"
        case .backslash: return "|"
        case .semicolon: return ":"
        case .quote: return "\""
        case .comma: return "<"
        case .period: return ">"
        case .slash: return "?"
        case .space: return " "
        default: return nil
        }
    }
}

nonisolated enum TerminalAccessorySystemActionID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case commandModifier
    case escape
    case tab
    case shiftTab
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

    var isRepeatable: Bool {
        switch self {
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .backspace, .home, .end, .pageUp, .pageDown:
            return true
        default:
            return false
        }
    }
}

nonisolated enum TerminalAccessoryItemRef: Codable, Hashable, Sendable {
    case system(TerminalAccessorySystemActionID)
    case custom(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case systemID
        case customActionID
        case snippetID
    }

    private enum Kind: String, Codable {
        case system
        case custom
        case snippet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .system:
            let id = try container.decode(TerminalAccessorySystemActionID.self, forKey: .systemID)
            self = .system(id)
        case .custom:
            let id = try container.decode(UUID.self, forKey: .customActionID)
            self = .custom(id)
        case .snippet:
            let id = try container.decode(UUID.self, forKey: .snippetID)
            self = .custom(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .system(let id):
            try container.encode(Kind.system, forKey: .kind)
            try container.encode(id, forKey: .systemID)
        case .custom(let id):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(id, forKey: .customActionID)
        }
    }
}

nonisolated struct TerminalAccessoryCustomAction: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var kind: TerminalAccessoryCustomActionKind
    var commandContent: String
    var commandSendMode: TerminalSnippetSendMode
    var shortcutKey: TerminalAccessoryShortcutKey
    var shortcutModifiers: TerminalAccessoryShortcutModifiers
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        kind: TerminalAccessoryCustomActionKind,
        commandContent: String = "",
        commandSendMode: TerminalSnippetSendMode = .insert,
        shortcutKey: TerminalAccessoryShortcutKey = .a,
        shortcutModifiers: TerminalAccessoryShortcutModifiers = .none,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.commandContent = commandContent
        self.commandSendMode = commandSendMode
        self.shortcutKey = shortcutKey
        self.shortcutModifiers = shortcutModifiers
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

}

nonisolated struct TerminalSnippet: Identifiable, Codable, Equatable, Sendable {
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

nonisolated struct TerminalAccessoryLayout: Codable, Equatable, Sendable {
    var version: Int
    var activeItems: [TerminalAccessoryItemRef]
    var updatedAt: Date
}

nonisolated struct TerminalAccessoryProfile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var layout: TerminalAccessoryLayout
    var customActions: [TerminalAccessoryCustomAction]
    var updatedAt: Date
    var lastWriterDeviceId: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case layout
        case customActions
        case snippets
        case updatedAt
        case lastWriterDeviceId
    }

    init(
        schemaVersion: Int,
        layout: TerminalAccessoryLayout,
        customActions: [TerminalAccessoryCustomAction],
        updatedAt: Date,
        lastWriterDeviceId: String
    ) {
        self.schemaVersion = schemaVersion
        self.layout = layout
        self.customActions = customActions
        self.updatedAt = updatedAt
        self.lastWriterDeviceId = lastWriterDeviceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        layout = try container.decodeIfPresent(TerminalAccessoryLayout.self, forKey: .layout)
            ?? TerminalAccessoryLayout(version: 1, activeItems: Self.defaultActiveItems, updatedAt: .distantPast)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        lastWriterDeviceId = try container.decodeIfPresent(String.self, forKey: .lastWriterDeviceId) ?? ""

        if let actions = try container.decodeIfPresent([TerminalAccessoryCustomAction].self, forKey: .customActions) {
            customActions = actions
        } else {
            let legacySnippets = try container.decodeIfPresent([TerminalSnippet].self, forKey: .snippets) ?? []
            customActions = legacySnippets.map(\.asCustomAction)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(layout, forKey: .layout)
        try container.encode(customActions, forKey: .customActions)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(lastWriterDeviceId, forKey: .lastWriterDeviceId)
    }
}

nonisolated extension TerminalAccessoryProfile {
    static let schemaVersion = 2
    static let recordType = "UserPreference"
    static let recordName = "terminalAccessory.v1"

    static let minActiveItems = 4
    static let maxActiveItems = 28
    static let maxCustomActions = 100
    static let maxCustomActionTitleLength = 24
    static let maxCommandContentLength = 2048

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

    static func defaultValue(lastWriterDeviceId: String) -> TerminalAccessoryProfile {
        TerminalAccessoryProfile(
            schemaVersion: schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: defaultActiveItems,
                updatedAt: .distantPast
            ),
            customActions: [],
            updatedAt: .distantPast,
            lastWriterDeviceId: lastWriterDeviceId
        )
    }

    static var availableSystemActions: [TerminalAccessorySystemActionID] {
        TerminalAccessorySystemActionID.allCases.filter { $0 != .unknown }
    }

    func normalized() -> TerminalAccessoryProfile {
        var customActionsByID: [UUID: TerminalAccessoryCustomAction] = [:]
        for action in customActions {
            let normalizedAction = action.normalized()
            if let existing = customActionsByID[normalizedAction.id] {
                if normalizedAction.updatedAt > existing.updatedAt {
                    customActionsByID[normalizedAction.id] = normalizedAction
                }
            } else {
                customActionsByID[normalizedAction.id] = normalizedAction
            }
        }

        let normalizedActions = customActionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let limitedActiveActionIDs = Set(
            normalizedActions
                .filter { !$0.isDeleted }
                .prefix(Self.maxCustomActions)
                .map(\.id)
        )

        let normalizedAndLimitedActions = normalizedActions.filter {
            $0.isDeleted || limitedActiveActionIDs.contains($0.id)
        }

        let activeActionIDs = Set(normalizedAndLimitedActions.filter { !$0.isDeleted }.map(\.id))

        var seenItems = Set<TerminalAccessoryItemRef>()
        var normalizedItems: [TerminalAccessoryItemRef] = []

        for item in layout.activeItems {
            switch item {
            case .system(let actionID):
                guard actionID != .unknown else { continue }
            case .custom(let actionID):
                guard activeActionIDs.contains(actionID) else { continue }
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
            schemaVersion: max(Self.schemaVersion, schemaVersion),
            layout: TerminalAccessoryLayout(
                version: max(1, layout.version),
                activeItems: normalizedItems,
                updatedAt: layout.updatedAt
            ),
            customActions: Array(normalizedAndLimitedActions),
            updatedAt: updatedAt,
            lastWriterDeviceId: lastWriterDeviceId
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

        var actionsByID: [UUID: TerminalAccessoryCustomAction] = [:]
        for action in normalizedRemote.customActions {
            actionsByID[action.id] = action
        }

        for action in normalizedLocal.customActions {
            if let existing = actionsByID[action.id] {
                if action.updatedAt >= existing.updatedAt {
                    actionsByID[action.id] = action
                }
            } else {
                actionsByID[action.id] = action
            }
        }

        let mergedActions = actionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let mergedUpdatedAt = max(
            normalizedLocal.updatedAt,
            normalizedRemote.updatedAt,
            mergedLayout.updatedAt,
            mergedActions.first?.updatedAt ?? .distantPast
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
            customActions: Array(mergedActions),
            updatedAt: mergedUpdatedAt,
            lastWriterDeviceId: writerDeviceID
        )
        .normalized()
    }
}

private nonisolated extension TerminalAccessoryCustomAction {
    func normalized() -> TerminalAccessoryCustomAction {
        let sanitizedTitle: String
        let sanitizedCommandContent: String

        if isDeleted {
            sanitizedTitle = ""
            sanitizedCommandContent = ""
        } else {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            sanitizedTitle = String(trimmedTitle.prefix(TerminalAccessoryProfile.maxCustomActionTitleLength))
            if kind == .command {
                sanitizedCommandContent = String(commandContent.prefix(TerminalAccessoryProfile.maxCommandContentLength))
            } else {
                sanitizedCommandContent = ""
            }
        }

        return TerminalAccessoryCustomAction(
            id: id,
            title: sanitizedTitle,
            kind: kind,
            commandContent: sanitizedCommandContent,
            commandSendMode: commandSendMode,
            shortcutKey: shortcutKey,
            shortcutModifiers: shortcutModifiers,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

private nonisolated extension TerminalSnippet {
    var asCustomAction: TerminalAccessoryCustomAction {
        TerminalAccessoryCustomAction(
            id: id,
            title: title,
            kind: .command,
            commandContent: content,
            commandSendMode: sendMode,
            shortcutKey: .a,
            shortcutModifiers: .none,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
