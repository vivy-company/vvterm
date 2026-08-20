import Foundation

@MainActor
private struct LiveServerStatsTarget: ServerStatsCollectionTarget {
    let server: Server

    var serverID: UUID { server.id }
}

@MainActor
private struct LiveServerStatsConnection: ServerStatsConnectionReference {
    let client: SSHClient

    var identity: ServerStatsConnectionIdentity {
        ServerStatsConnectionIdentity(client)
    }
}

@MainActor
final class LiveServerStatsApprovalReference: ServerStatsApprovalReference {
    let rawValue: ServerSecurityApprovalRequest
    let request: ServerStatsApprovalRequest

    init(_ rawValue: ServerSecurityApprovalRequest, serverID: UUID) {
        self.rawValue = rawValue
        request = ServerStatsApprovalRequest(
            id: rawValue.id,
            serverID: serverID
        )
    }
}

@MainActor
extension ServerStatsCollectorDependencies {
    static func live(
        keychainManager: KeychainManager,
        knownHostsManager: KnownHostsManager,
        connectionOperations: SSHConnectionOperationService,
        sshClientFactory: SSHClientFactory
    ) -> Self {
        ServerStatsCollectorDependencies(
            makeOwnedConnection: {
                LiveServerStatsConnection(client: sshClientFactory.makeClient())
            },
            makeSession: { target, connection, ownership in
                guard let target = target as? LiveServerStatsTarget,
                      let connection = connection as? LiveServerStatsConnection else {
                    throw LiveServerStatsAdapterError.incompatibleReference
                }

                let credentials = try keychainManager.getCredentials(for: target.server)

                return LiveServerStatsCollectionSession(
                    server: target.server,
                    credentials: credentials,
                    client: connection.client,
                    ownership: ownership,
                    connectionOperations: connectionOperations,
                    knownHostsManager: knownHostsManager
                )
            },
            makeAttemptID: UUID.init
        )
    }
}

@MainActor
extension ServerStatsCollector {
    var securityApproval: ServerSecurityApprovalRequest? {
        (approvalReferenceForPresentation as? LiveServerStatsApprovalReference)?.rawValue
    }

    func startCollecting(
        for server: Server,
        using sharedClient: SSHClient? = nil,
        collectDocker: Bool = false
    ) async {
        await startCollecting(
            for: LiveServerStatsTarget(server: server),
            using: sharedClient.map(LiveServerStatsConnection.init(client:)),
            collectDocker: collectDocker
        )
    }

    func resolveSecurityApproval(
        _ request: ServerSecurityApprovalRequest,
        error: ServerSecurityApprovalError? = nil
    ) {
        guard let reference = approvalReferenceForPresentation as? LiveServerStatsApprovalReference,
              reference.rawValue == request else { return }
        let failure: ServerStatsCollectionFailure?
        switch error {
        case .some(.cancelled):
            failure = .securityApprovalCancelled
        case .some(.expired):
            failure = .securityApprovalExpired
        case .some(.unavailable):
            failure = .securityApprovalUnavailable
        case nil:
            failure = nil
        }
        resolveSecurityApproval(
            reference.request,
            failure: failure
        )
    }
}

private enum LiveServerStatsAdapterError: LocalizedError {
    case incompatibleReference

    var errorDescription: String? {
        String(localized: "Stats received an incompatible connection reference.")
    }
}
