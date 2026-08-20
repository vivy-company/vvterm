import Foundation

@MainActor
final class TerminalConnectionTaskStore {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var entries: [UUID: Entry] = [:]

    var paneIds: Set<UUID> {
        Set(entries.keys)
    }

    @discardableResult
    func start(
        for paneId: UUID,
        operation: @escaping @Sendable (_ taskId: UUID) async -> Void
    ) -> UUID? {
        guard entries[paneId] == nil else { return nil }

        let taskId = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await operation(taskId)
            await self?.finish(taskId: taskId, for: paneId)
        }
        entries[paneId] = Entry(id: taskId, task: task)
        return taskId
    }

    func isCurrent(taskId: UUID, for paneId: UUID) -> Bool {
        entries[paneId]?.id == taskId
    }

    @discardableResult
    func cancel(for paneId: UUID) -> Bool {
        guard let entry = entries.removeValue(forKey: paneId) else { return false }
        entry.task.cancel()
        return true
    }

    func cancelAll() {
        let tasks = entries.values.map(\.task)
        entries.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func finish(taskId: UUID, for paneId: UUID) {
        guard entries[paneId]?.id == taskId else { return }
        entries.removeValue(forKey: paneId)
    }
}

struct TerminalSSHConnectionContext {
    let isCurrent: @MainActor @Sendable () -> Bool
    let updateConnectionState: @MainActor @Sendable (ConnectionState) -> Void
    let startupPlan: @MainActor @Sendable () async throws -> TerminalShellStartupPlan
    let restoreMoshShell: @MainActor @Sendable (_ cols: Int, _ rows: Int) async -> ShellHandle?
    let registerShell: @MainActor @Sendable (ShellHandle) async -> Bool
    let persistMoshCheckpoint: @MainActor @Sendable (_ shellId: UUID) async -> Void
    let updateTitle: @MainActor @Sendable (String) -> Void
    let hasOtherRegistrations: @MainActor @Sendable () async -> Bool
    let handleShellEnd: @MainActor @Sendable (_ shellId: UUID, _ reason: TerminalShellEndReason) -> Void
    let handleFailure: @MainActor @Sendable (TerminalConnectionFailure) -> Void
    let workingDirectory: @MainActor @Sendable () -> String?
}

nonisolated extension TerminalConnectionFailure {
    static func transport(_ error: Error) -> Self {
        let message = error.localizedDescription
        guard let sshError = error as? SSHError else {
            return .external(
                message: message,
                retryDisposition: .automatic,
                requiredAction: message.contains("host key approval is required")
                    ? .approveHostKey
                    : nil
            )
        }

        let requiredAction: TerminalConnectionRequiredAction? = switch sshError {
        case .hostKeyApprovalRequired:
            .approveHostKey
        default:
            nil
        }
        return .external(
            message: message,
            retryDisposition: sshError.allowsAutomaticReconnectRetry ? .automatic : .manual,
            requiredAction: requiredAction
        )
    }
}
