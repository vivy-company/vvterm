import Foundation

nonisolated enum FreePlanGeneration: String, Equatable, Sendable {
    case legacyThreeServers = "legacy_three_servers"
    case currentOneServer = "current_one_server"

    var serverLimit: Int {
        switch self {
        case .legacyThreeServers: return FreeTierLimits.legacyMaxServers
        case .currentOneServer: return FreeTierLimits.currentMaxServers
        }
    }
}

nonisolated struct ServerFreeTierPolicy: Equatable, Sendable {
    let generation: FreePlanGeneration

    var serverLimit: Int {
        generation.serverLimit
    }

    var isLegacyPlan: Bool {
        generation == .legacyThreeServers
    }

    func canAddServer(serverCount: Int, hasProAccess: Bool) -> Bool {
        hasProAccess || serverCount < serverLimit
    }

    func canAddWorkspace(workspaceCount: Int, hasProAccess: Bool) -> Bool {
        hasProAccess || workspaceCount < FreeTierLimits.maxWorkspaces
    }

    func unlockedServerIDs(servers: [Server], hasProAccess: Bool) -> Set<UUID> {
        if hasProAccess {
            return Set(servers.map(\.id))
        }
        let prioritized = servers.sorted { $0.createdAt < $1.createdAt }
        return Set(prioritized.prefix(serverLimit).map(\.id))
    }

    func unlockedWorkspaceIDs(workspaces: [Workspace], hasProAccess: Bool) -> Set<UUID> {
        if hasProAccess {
            return Set(workspaces.map(\.id))
        }
        let prioritized = workspaces.sorted { $0.order < $1.order }
        return Set(prioritized.prefix(FreeTierLimits.maxWorkspaces).map(\.id))
    }

    func lockedServerCount(serverCount: Int, hasProAccess: Bool) -> Int {
        hasProAccess ? 0 : max(0, serverCount - serverLimit)
    }

    func lockedWorkspaceCount(workspaceCount: Int, hasProAccess: Bool) -> Int {
        hasProAccess ? 0 : max(0, workspaceCount - FreeTierLimits.maxWorkspaces)
    }
}
