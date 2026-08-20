import Foundation

nonisolated enum TerminalSecurityApprovalFailure: Equatable, Sendable {
    case expired
}

nonisolated enum TerminalSecurityApprovalOutcome: Equatable, Sendable {
    case approved
    case failed(TerminalSecurityApprovalFailure)
}

/// App-owned security effects used by terminal session presentation.
@MainActor
struct TerminalSecurityActions {
    typealias LoadCredentials = @MainActor @Sendable (Server) throws -> ServerCredentials
    typealias PendingHostKeyApproval = @MainActor @Sendable (
        _ server: Server
    ) -> ServerSecurityApprovalRequest?
    typealias Approve = @MainActor @Sendable (
        _ request: ServerSecurityApprovalRequest,
        _ server: Server
    ) -> TerminalSecurityApprovalOutcome
    typealias Reject = @MainActor @Sendable (
        _ request: ServerSecurityApprovalRequest
    ) -> Void

    let loadCredentials: LoadCredentials
    let pendingHostKeyApproval: PendingHostKeyApproval
    let approve: Approve
    let reject: Reject
}
