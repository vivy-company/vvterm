import Foundation

nonisolated enum ServerMutationCommand: Equatable, Sendable {
    case insertServer(Server)
    case updateServer(Server)
    case deleteServer(UUID)
    case insertWorkspace(Workspace)
    case updateWorkspace(Workspace)
}

nonisolated enum ServerMutationEffect: Equatable, Sendable {
    case serverUpsert(Server)
    case serverDelete(Server)
    case workspaceUpsert(Workspace)
}

nonisolated struct ServerMutationCommandResult: Equatable, Sendable {
    let servers: [Server]
    let workspaces: [Workspace]
    let effect: ServerMutationEffect
}

nonisolated struct ServerMutationCommandRepository: Sendable {
    func execute(
        _ command: ServerMutationCommand,
        servers: [Server],
        workspaces: [Workspace],
        now: Date
    ) throws -> ServerMutationCommandResult {
        switch command {
        case .insertServer(let server):
            let inserted = serverForInsertion(server, now: now)
            return ServerMutationCommandResult(
                servers: servers + [inserted],
                workspaces: workspaces,
                effect: .serverUpsert(inserted)
            )

        case .updateServer(let server):
            let index = try existingServerIndex(for: server.id, in: servers)
            let updated = serverForUpdate(server, now: now)
            var result = servers
            result[index] = updated
            return ServerMutationCommandResult(
                servers: result,
                workspaces: workspaces,
                effect: .serverUpsert(updated)
            )

        case .deleteServer(let serverID):
            let index = try existingServerIndex(for: serverID, in: servers)
            let deleted = servers[index]
            var result = servers
            result.remove(at: index)
            return ServerMutationCommandResult(
                servers: result,
                workspaces: workspaces,
                effect: .serverDelete(deleted)
            )

        case .insertWorkspace(let workspace):
            let inserted = Workspace(
                id: workspace.id,
                name: workspace.name,
                colorHex: workspace.colorHex,
                icon: workspace.icon,
                order: workspaces.count,
                createdAt: now,
                updatedAt: now
            )
            return ServerMutationCommandResult(
                servers: servers,
                workspaces: workspaces + [inserted],
                effect: .workspaceUpsert(inserted)
            )

        case .updateWorkspace(let workspace):
            let index = try existingWorkspaceIndex(for: workspace.id, in: workspaces)
            let updated = Workspace(
                id: workspace.id,
                name: workspace.name,
                colorHex: workspace.colorHex,
                icon: workspace.icon,
                order: workspace.order,
                environments: workspace.environments,
                lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
                lastSelectedServerId: workspace.lastSelectedServerId,
                createdAt: workspace.createdAt,
                updatedAt: now
            )
            var result = workspaces
            result[index] = updated
            return ServerMutationCommandResult(
                servers: servers,
                workspaces: result,
                effect: .workspaceUpsert(updated)
            )
        }
    }

    func existingServerIndex(for id: UUID, in servers: [Server]) throws -> Int {
        guard let index = servers.firstIndex(where: { $0.id == id }) else {
            throw VVTermError.serverNotFound
        }
        return index
    }

    func existingWorkspaceIndex(for id: UUID, in workspaces: [Workspace]) throws -> Int {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw VVTermError.workspaceNotFound
        }
        return index
    }

    private func serverForInsertion(_ server: Server, now: Date) -> Server {
        Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            eternalTerminalPort: server.eternalTerminalPort,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            cloudflareAccessMode: server.cloudflareAccessMode,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            tags: server.tags,
            notes: server.notes,
            requiresBiometricUnlock: server.requiresBiometricUnlock,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            tmuxStartupBehaviorOverride: server.tmuxStartupBehaviorOverride,
            createdAt: now,
            updatedAt: now
        )
    }

    private func serverForUpdate(_ server: Server, now: Date) -> Server {
        Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            eternalTerminalPort: server.eternalTerminalPort,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            cloudflareAccessMode: server.cloudflareAccessMode,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            tags: server.tags,
            notes: server.notes,
            lastConnected: server.lastConnected,
            isFavorite: server.isFavorite,
            requiresBiometricUnlock: server.requiresBiometricUnlock,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            tmuxStartupBehaviorOverride: server.tmuxStartupBehaviorOverride,
            createdAt: server.createdAt,
            updatedAt: now
        )
    }
}
