import Foundation

nonisolated enum ServerStatsSecurityApprovalOutcome: Equatable, Sendable {
    case approved
    case failed(ServerSecurityApprovalError)
}

/// Security effects required by the stats approval presentation.
///
/// The app composition root supplies the live authorization, credential, and
/// known-host implementations. Stats UI only owns presentation and retry flow.
@MainActor
struct ServerStatsSecurityApprovalActions {
    typealias Approve = @MainActor (
        _ request: ServerSecurityApprovalRequest
    ) async -> ServerStatsSecurityApprovalOutcome
    typealias Reject = @MainActor (_ request: ServerSecurityApprovalRequest) -> Void

    let approve: Approve
    let reject: Reject
}

/// Stable app-owned dependencies for Stats screens.
@MainActor
struct ServerStatsScreenDependencies {
    let runtimeStore: ServerStatsRuntimeStore
    let preferencesStore: PreferencesStore
    let volumeVisibilityStore: ServerVolumeVisibilityStore
    let securityApprovalActions: ServerStatsSecurityApprovalActions
}
