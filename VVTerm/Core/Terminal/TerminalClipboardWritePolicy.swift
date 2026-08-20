import Foundation

nonisolated enum TerminalRemoteClipboardReadPolicy: String, CaseIterable, Identifiable, Sendable {
    case deny
    case ask
    case allow

    static let userDefaultsKey = "terminalRemoteClipboardReadPolicy"
    static let defaultValue: TerminalRemoteClipboardReadPolicy = .ask

    var id: String { rawValue }

    var settingsTitle: String {
        switch self {
        case .deny: return String(localized: "Deny")
        case .ask: return String(localized: "Ask Every Time")
        case .allow: return String(localized: "Always Allow")
        }
    }

    var settingsDescription: String {
        switch self {
        case .deny:
            return String(localized: "Remote programs cannot read your clipboard.")
        case .ask:
            return String(localized: "VVTerm asks before a remote program reads your clipboard.")
        case .allow:
            return String(localized: "Warning: Remote programs can read your clipboard without asking.")
        }
    }

    static func resolved(defaults: UserDefaults = .standard) -> TerminalRemoteClipboardReadPolicy {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let policy = TerminalRemoteClipboardReadPolicy(rawValue: rawValue) else {
            return defaultValue
        }
        return policy
    }
}

nonisolated enum TerminalClipboardWriteAction: Equatable, Sendable {
    case writeImmediately
    case requestConfirmation
}

nonisolated enum TerminalClipboardWritePolicy {
    static func action(requiresConfirmation: Bool) -> TerminalClipboardWriteAction {
        requiresConfirmation ? .requestConfirmation : .writeImmediately
    }
}

nonisolated enum TerminalClipboardConfirmationKind: Equatable, Sendable {
    case remoteRead
    case remoteWrite
    case unsafePaste

    var title: String {
        switch self {
        case .remoteRead: return String(localized: "Allow Clipboard Read?")
        case .remoteWrite: return String(localized: "Allow Clipboard Change?")
        case .unsafePaste: return String(localized: "Allow Paste?")
        }
    }

    var message: String {
        switch self {
        case .remoteRead:
            return String(localized: "The remote terminal wants to read your clipboard.")
        case .remoteWrite:
            return String(localized: "The remote terminal wants to replace your clipboard.")
        case .unsafePaste:
            return String(localized: "The clipboard text may contain commands or multiple lines.")
        }
    }
}

nonisolated enum TerminalClipboardConfirmationDecision: Equatable, Sendable {
    case cancel
    case allow
}

nonisolated enum TerminalClipboardPresentationRetryAction: Equatable, Sendable {
    case retry(nextAttempt: Int)
    case cancel
}

nonisolated enum TerminalClipboardPresentationRetryPolicy {
    static let maximumAttempts = 480

    static func action(after attemptCount: Int) -> TerminalClipboardPresentationRetryAction {
        guard attemptCount < maximumAttempts else { return .cancel }
        return .retry(nextAttempt: attemptCount + 1)
    }
}

@MainActor
final class TerminalClipboardConfirmationQueue {
    static let maximumRequestCount = 8

    struct Request: Identifiable {
        let id: UUID
        let kind: TerminalClipboardConfirmationKind
        fileprivate let completion: (TerminalClipboardConfirmationDecision) -> Void
    }

    private var pending: [Request] = []
    private(set) var current: Request?

    var requestToPresent: Request? {
        if current == nil, !pending.isEmpty {
            current = pending.removeFirst()
        }
        return current
    }

    @discardableResult
    func enqueue(
        kind: TerminalClipboardConfirmationKind,
        completion: @escaping (TerminalClipboardConfirmationDecision) -> Void
    ) -> UUID {
        let request = Request(id: UUID(), kind: kind, completion: completion)
        if kind == .remoteWrite,
           current?.kind == .remoteWrite || pending.contains(where: { $0.kind == .remoteWrite }) {
            completion(.cancel)
            return request.id
        }
        let requestCount = pending.count + (current == nil ? 0 : 1)
        guard requestCount < Self.maximumRequestCount else {
            completion(.cancel)
            return request.id
        }
        pending.append(request)
        return request.id
    }

    @discardableResult
    func resolve(
        id: UUID,
        decision: TerminalClipboardConfirmationDecision
    ) -> Bool {
        guard let current, current.id == id else { return false }
        self.current = nil
        current.completion(decision)
        return true
    }

    func cancelAll() {
        var requests = pending
        if let current {
            requests.insert(current, at: 0)
        }
        pending.removeAll(keepingCapacity: false)
        current = nil
        for request in requests {
            request.completion(.cancel)
        }
    }
}
