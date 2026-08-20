import Foundation

extension AppComposition {
    static func makeRemoteFileSecurityApprovalActions(
        knownHostsManager: KnownHostsManager
    ) -> RemoteFileSecurityApprovalActions {
        RemoteFileSecurityApprovalActions(
            pendingRequest: { error, server in
                if let request = ServerSecurityApprovalRequest.detect(
                    error,
                    host: server.host,
                    port: server.port,
                    knownHosts: knownHostsManager
                ) {
                    return request
                }
                guard RemoteFileBrowserError.map(error) == .hostKeyApprovalRequired else {
                    return nil
                }
                return knownHostsManager.pendingChallenge(
                    for: server.host,
                    port: server.port
                ).map(ServerSecurityApprovalRequest.hostKey)
            },
            approve: { request in
                switch request {
                case .hostKey(let challenge):
                    return knownHostsManager.approve(challenge)
                }
            },
            reject: { request in
                switch request {
                case .hostKey(let challenge):
                    knownHostsManager.reject(challenge)
                }
            }
        )
    }

    static func makeStatsCollectorFactory(
        keychainManager: KeychainManager,
        knownHostsManager: KnownHostsManager,
        connectionOperations: SSHConnectionOperationService,
        sshClientFactory: SSHClientFactory
    ) -> @MainActor () -> ServerStatsCollector {
        let dependencies = ServerStatsCollectorDependencies.live(
            keychainManager: keychainManager,
            knownHostsManager: knownHostsManager,
            connectionOperations: connectionOperations,
            sshClientFactory: sshClientFactory
        )
        return {
            ServerStatsCollector(dependencies: dependencies)
        }
    }

    static func makeTerminalSecurityActions(
        keychainManager: KeychainManager,
        knownHostsManager: KnownHostsManager
    ) -> TerminalSecurityActions {
        TerminalSecurityActions(
            loadCredentials: { server in
                try keychainManager.getCredentials(for: server)
            },
            pendingHostKeyApproval: { server in
                knownHostsManager.pendingChallenge(
                    for: server.host,
                    port: server.port
                ).map(ServerSecurityApprovalRequest.hostKey)
            },
            approve: { request, _ in
                switch request {
                case .hostKey(let challenge):
                    return knownHostsManager.approve(challenge)
                        ? .approved
                        : .failed(.expired)
                }
            },
            reject: { request in
                switch request {
                case .hostKey(let challenge):
                    knownHostsManager.reject(challenge)
                }
            }
        )
    }

    static func makeStatsSecurityApprovalActions(
        knownHostsManager: KnownHostsManager
    ) -> ServerStatsSecurityApprovalActions {
        ServerStatsSecurityApprovalActions(
            approve: { request in
                switch request {
                case .hostKey(let challenge):
                    return knownHostsManager.approve(challenge)
                        ? .approved
                        : .failed(.expired)
                }
            },
            reject: { request in
                switch request {
                case .hostKey(let challenge):
                    knownHostsManager.reject(challenge)
                }
            }
        )
    }

    static func makeRemoteFileBrowserStore(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        credentialRepository: any ServerCredentialTransactionRepository,
        connectionOperations: SSHConnectionOperationService,
        clientFactory: SSHClientFactory,
        securityApprovalActions: RemoteFileSecurityApprovalActions,
        defaults: UserDefaults
    ) -> RemoteFileBrowserStore {
        let adapter = SSHSFTPAdapter(
            borrowedClientProvider: { serverId in
                tabManager.transportCoordinator.sharedStatsClient(for: serverId)
            },
            credentialRepository: credentialRepository,
            connectionOperations: connectionOperations,
            clientFactory: clientFactory
        )

        return RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: adapter,
            securityApprovalActions: securityApprovalActions,
            serverProvider: { serverId in
                serverManager.servers.first { $0.id == serverId }
            },
            workingDirectoryProvider: { serverId in
                tabManager.workingDirectoryCandidate(for: serverId)
            }
        )
    }
}
