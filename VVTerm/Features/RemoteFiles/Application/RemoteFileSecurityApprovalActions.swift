import Foundation

@MainActor
struct RemoteFileSecurityApprovalActions {
    typealias PendingRequest = @MainActor (
        _ error: Error,
        _ server: Server
    ) -> ServerSecurityApprovalRequest?
    typealias Approve = @MainActor (_ request: ServerSecurityApprovalRequest) -> Bool
    typealias Reject = @MainActor (_ request: ServerSecurityApprovalRequest) -> Void

    let pendingRequest: PendingRequest
    let approve: Approve
    let reject: Reject

    static let unavailable = RemoteFileSecurityApprovalActions(
        pendingRequest: { _, _ in nil },
        approve: { _ in false },
        reject: { _ in }
    )
}
