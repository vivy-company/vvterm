import Foundation
import Combine
import SwiftUI
import os.log

// MARK: - Server Manager

@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var servers: [Server] = []
    @Published var workspaces: [Workspace] = []
    @Published var isLoading = false
    @Published var error: String?

    private let cloudKit = CloudKitManager.shared
    private let keychain = KeychainManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ServerManager")
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }

    // Local storage keys
    private let serversKey = "com.vivy.vivyterm.servers"
    private let workspacesKey = "com.vivy.vivyterm.workspaces"

    private init() {
        // Load local data first (fast)
        loadLocalData()
        // Then sync with CloudKit in background
        Task { await loadData() }
    }

    // MARK: - Local Storage

    private func loadLocalData() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([Server].self, from: data) {
            servers = decoded
            logger.info("Loaded \(decoded.count) servers from local storage")
        }

        if let data = UserDefaults.standard.data(forKey: workspacesKey),
           let decoded = try? JSONDecoder().decode([Workspace].self, from: data) {
            workspaces = decoded
            logger.info("Loaded \(decoded.count) workspaces from local storage")
        }

        // Ensure at least one workspace exists
        if workspaces.isEmpty {
            workspaces = [createDefaultWorkspace()]
            saveLocalData()
        }
    }

    private func saveLocalData() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: workspacesKey)
        }
    }

    /// Clear all local data and re-download from CloudKit
    func clearLocalDataAndResync() async {
        logger.info("Clearing local data and re-syncing from CloudKit...")

        // Clear local storage
        UserDefaults.standard.removeObject(forKey: serversKey)
        UserDefaults.standard.removeObject(forKey: workspacesKey)

        // Clear in-memory data
        servers = []
        workspaces = []
        error = nil

        // Re-fetch from CloudKit
        await loadData()

        logger.info("Clear and re-sync complete: \(self.workspaces.count) workspaces, \(self.servers.count) servers")
    }

    // MARK: - Data Loading

    func loadData() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard isSyncEnabled else {
            logger.info("iCloud sync disabled; using local data only")
            return
        }

        do {
            let changes = try await cloudKit.fetchChanges()

            // Merge CloudKit data with local (CloudKit wins for conflicts, dedupe by ID)
            logger.info(
                "CloudKit returned \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
            )

            applyCloudKitChanges(changes)

            // Ensure at least one workspace exists before checking orphans
            if workspaces.isEmpty {
                workspaces = [createDefaultWorkspace()]
                if isSyncEnabled {
                    try await cloudKit.saveWorkspace(workspaces[0])
                }
                logger.info("Created default workspace: \(self.workspaces[0].name)")
            }

            // Check for and repair orphaned servers (workspaceId doesn't match any workspace)
            await repairOrphanedServers()

            // Save merged data locally
            saveLocalData()

            logger.info("Loaded \(self.workspaces.count) workspaces and \(self.servers.count) servers from CloudKit")
        } catch {
            logger.error("Failed to load from CloudKit: \(error.localizedDescription)")
            self.error = error.localizedDescription
            // Local data is already loaded in init, so nothing to do here
            logger.info("Using local data: \(self.workspaces.count) workspaces and \(self.servers.count) servers")

            // Only try to push local data if it's a schema error (record type not found)
            // This auto-creates schema in development mode
            if cloudKit.isAvailable && CloudKitManager.isSchemaError(error) {
                logger.info("Schema error detected, attempting to initialize schema...")
                await initializeCloudKitSchema()
            }
        }
    }

    private func createDefaultWorkspace() -> Workspace {
        Workspace(
            name: String(localized: "My Servers"),
            colorHex: "#007AFF",
            order: 0
        )
    }

    private func applyCloudKitChanges(_ changes: CloudKitChanges) {
        if changes.isFullFetch {
            if !changes.workspaces.isEmpty {
                workspaces = dedupedWorkspaces(from: changes.workspaces)
            }
            if !changes.servers.isEmpty {
                servers = dedupedServers(from: changes.servers)
            }
            return
        }

        if !changes.workspaces.isEmpty {
            upsertWorkspaces(changes.workspaces)
        }
        if !changes.deletedWorkspaceIDs.isEmpty {
            removeWorkspaces(withIDs: changes.deletedWorkspaceIDs)
        }
        if !changes.servers.isEmpty {
            upsertServers(changes.servers)
        }
        if !changes.deletedServerIDs.isEmpty {
            removeServers(withIDs: changes.deletedServerIDs)
        }
    }

    private func dedupedWorkspaces(from updates: [Workspace]) -> [Workspace] {
        var workspaceMap: [UUID: Workspace] = [:]
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
            logger.info("Workspace from CloudKit: \(workspace.name) (id: \(workspace.id))")
        }
        return Array(workspaceMap.values).sorted { $0.order < $1.order }
    }

    private func dedupedServers(from updates: [Server]) -> [Server] {
        var serverMap: [UUID: Server] = [:]
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        return Array(serverMap.values).sorted { $0.name < $1.name }
    }

    private func upsertWorkspaces(_ updates: [Workspace]) {
        var workspaceMap = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
            logger.info("Workspace updated from CloudKit: \(workspace.name) (id: \(workspace.id))")
        }
        workspaces = Array(workspaceMap.values).sorted { $0.order < $1.order }
    }

    private func upsertServers(_ updates: [Server]) {
        var serverMap = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server updated from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        servers = Array(serverMap.values).sorted { $0.name < $1.name }
    }

    private func removeWorkspaces(withIDs ids: [UUID]) {
        let idSet = Set(ids)
        workspaces.removeAll { idSet.contains($0.id) }
    }

    private func removeServers(withIDs ids: [UUID]) {
        let idSet = Set(ids)
        servers.removeAll { idSet.contains($0.id) }
    }

    /// Repairs servers that reference non-existent workspaces by reassigning them to the first available workspace
    private func repairOrphanedServers() async {
        let workspaceIds = Set(workspaces.map { $0.id })
        let orphanedServers = servers.filter { !workspaceIds.contains($0.workspaceId) }

        guard !orphanedServers.isEmpty else { return }

        logger.warning("Found \(orphanedServers.count) ORPHANED servers (workspaceId doesn't match any workspace):")
        for server in orphanedServers {
            logger.warning("  - \(server.name) (id: \(server.id)) references missing workspaceId: \(server.workspaceId)")
        }

        // Auto-repair: reassign orphaned servers to first workspace
        let defaultWorkspace = workspaces[0]
        logger.info("Auto-repairing: reassigning orphaned servers to workspace '\(defaultWorkspace.name)'")
        for i in servers.indices {
            if !workspaceIds.contains(servers[i].workspaceId) {
                let oldWorkspaceId = servers[i].workspaceId
                servers[i] = Server(
                    id: servers[i].id,
                    workspaceId: defaultWorkspace.id,
                    environment: servers[i].environment,
                    name: servers[i].name,
                    host: servers[i].host,
                    port: servers[i].port,
                    username: servers[i].username,
                    authMethod: servers[i].authMethod,
                    tags: servers[i].tags,
                    notes: servers[i].notes,
                    lastConnected: servers[i].lastConnected,
                    isFavorite: servers[i].isFavorite,
                    tmuxEnabledOverride: servers[i].tmuxEnabledOverride,
                    createdAt: servers[i].createdAt,
                    updatedAt: Date()
                )
                logger.info("Reassigned server '\(self.servers[i].name)' from \(oldWorkspaceId) to \(defaultWorkspace.id)")

                // Save updated server to CloudKit
                do {
                    if isSyncEnabled {
                        try await cloudKit.saveServer(servers[i])
                    }
                } catch {
                    logger.warning("Failed to save repaired server to CloudKit: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Push local data to CloudKit to auto-create schema in development mode
    private func initializeCloudKitSchema() async {
        logger.info("Attempting to initialize CloudKit schema by pushing local data...")

        // Push workspaces first
        for workspace in workspaces {
            do {
                if isSyncEnabled {
                    try await cloudKit.saveWorkspace(workspace)
                }
                logger.info("Pushed workspace to CloudKit: \(workspace.name)")
            } catch {
                logger.error("Failed to push workspace \(workspace.name): \(error.localizedDescription)")
            }
        }

        // Push servers
        for server in servers {
            do {
                if isSyncEnabled {
                    try await cloudKit.saveServer(server)
                }
                logger.info("Pushed server to CloudKit: \(server.name)")
            } catch {
                logger.error("Failed to push server \(server.name): \(error.localizedDescription)")
            }
        }

        logger.info("CloudKit schema initialization complete")
    }

    // MARK: - Server CRUD

    func addServer(_ server: Server, credentials: ServerCredentials) async throws {
        guard canAddServer else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for unlimited servers"))
        }

        var newServer = server
        newServer = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            tags: server.tags,
            notes: server.notes,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            createdAt: Date(),
            updatedAt: Date()
        )

        // Store credentials
        if let password = credentials.password {
            try keychain.storePassword(for: newServer.id, password: password)
        }
        if let sshKey = credentials.sshKey {
            try keychain.storeSSHKey(
                for: newServer.id,
                privateKey: sshKey,
                passphrase: credentials.sshPassphrase,
                publicKey: credentials.publicKey
            )
        }

        // Save to CloudKit (ignore errors, local is primary)
        do {
            if isSyncEnabled {
                try await cloudKit.saveServer(newServer)
            }
        } catch {
            logger.warning("CloudKit save failed, using local storage: \(error.localizedDescription)")
        }

        servers.append(newServer)
        saveLocalData()
        logger.info("Added server: \(newServer.name)")
    }

    func updateServer(_ server: Server) async throws {
        var updatedServer = server
        updatedServer = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            tags: server.tags,
            notes: server.notes,
            lastConnected: server.lastConnected,
            isFavorite: server.isFavorite,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            createdAt: server.createdAt,
            updatedAt: Date()
        )

        // Save to CloudKit (ignore errors, local is primary)
        do {
            if isSyncEnabled {
                try await cloudKit.saveServer(updatedServer)
            }
        } catch {
            logger.warning("CloudKit save failed, using local storage: \(error.localizedDescription)")
        }

        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = updatedServer
        }
        saveLocalData()
        logger.info("Updated server: \(updatedServer.name)")
    }

    func deleteServer(_ server: Server) async throws {
        // Delete from CloudKit (ignore errors)
        do {
            if isSyncEnabled {
                try await cloudKit.deleteServer(server)
            }
        } catch {
            logger.warning("CloudKit delete failed: \(error.localizedDescription)")
        }
        try keychain.deleteCredentials(for: server.id)

        servers.removeAll { $0.id == server.id }
        saveLocalData()
        logger.info("Deleted server: \(server.name)")
    }

    func updateLastConnected(for server: Server) async {
        var updated = server
        updated = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            authMethod: server.authMethod,
            tags: server.tags,
            notes: server.notes,
            lastConnected: Date(),
            isFavorite: server.isFavorite,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            createdAt: server.createdAt,
            updatedAt: Date()
        )

        try? await updateServer(updated)
    }

    // MARK: - Workspace CRUD

    func addWorkspace(_ workspace: Workspace) async throws {
        guard canAddWorkspace else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for unlimited workspaces"))
        }

        var newWorkspace = workspace
        newWorkspace = Workspace(
            id: workspace.id,
            name: workspace.name,
            colorHex: workspace.colorHex,
            icon: workspace.icon,
            order: workspaces.count,
            createdAt: Date(),
            updatedAt: Date()
        )

        // Save to CloudKit (ignore errors, local is primary)
        do {
            if isSyncEnabled {
                try await cloudKit.saveWorkspace(newWorkspace)
            }
        } catch {
            logger.warning("CloudKit save failed, using local storage: \(error.localizedDescription)")
        }

        workspaces.append(newWorkspace)
        saveLocalData()
        logger.info("Added workspace: \(newWorkspace.name)")
    }

    func updateWorkspace(_ workspace: Workspace) async throws {
        var updatedWorkspace = workspace
        updatedWorkspace = Workspace(
            id: workspace.id,
            name: workspace.name,
            colorHex: workspace.colorHex,
            icon: workspace.icon,
            order: workspace.order,
            environments: workspace.environments,
            lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
            lastSelectedServerId: workspace.lastSelectedServerId,
            createdAt: workspace.createdAt,
            updatedAt: Date()
        )

        // Save to CloudKit (ignore errors, local is primary)
        do {
            if isSyncEnabled {
                try await cloudKit.saveWorkspace(updatedWorkspace)
            }
        } catch {
            logger.warning("CloudKit save failed, using local storage: \(error.localizedDescription)")
        }

        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = updatedWorkspace
        }
        saveLocalData()
        logger.info("Updated workspace: \(updatedWorkspace.name)")
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        // Delete all servers in workspace
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }
        for server in workspaceServers {
            try await deleteServer(server)
        }

        // Delete from CloudKit (ignore errors)
        do {
            if isSyncEnabled {
                try await cloudKit.deleteWorkspace(workspace)
            }
        } catch {
            logger.warning("CloudKit delete failed: \(error.localizedDescription)")
        }

        workspaces.removeAll { $0.id == workspace.id }
        saveLocalData()
        logger.info("Deleted workspace: \(workspace.name)")
    }

    func reorderWorkspaces(from source: IndexSet, to destination: Int) async throws {
        workspaces.move(fromOffsets: source, toOffset: destination)

        // Update order for all workspaces
        for (index, workspace) in workspaces.enumerated() {
            var updated = workspace
            updated = Workspace(
                id: workspace.id,
                name: workspace.name,
                colorHex: workspace.colorHex,
                icon: workspace.icon,
                order: index,
                environments: workspace.environments,
                lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
                lastSelectedServerId: workspace.lastSelectedServerId,
                createdAt: workspace.createdAt,
                updatedAt: Date()
            )
            workspaces[index] = updated
            // Save to CloudKit (ignore errors)
            do {
                if isSyncEnabled {
                    try await cloudKit.saveWorkspace(updated)
                }
            } catch {
                logger.warning("CloudKit save failed: \(error.localizedDescription)")
            }
        }
        saveLocalData()
        logger.info("Reordered workspaces")
    }

    // MARK: - Queries

    func servers(in workspace: Workspace, environment: ServerEnvironment?) -> [Server] {
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }

        guard let environment = environment else {
            return workspaceServers
        }

        return workspaceServers.filter { $0.environment.id == environment.id }
    }

    func recentServers(limit: Int = 5) -> [Server] {
        servers
            .filter { $0.lastConnected != nil }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func favoriteServers() -> [Server] {
        servers.filter { $0.isFavorite }
    }

    func searchServers(_ query: String) -> [Server] {
        guard !query.isEmpty else { return servers }
        let lowercased = query.lowercased()
        return servers.filter {
            $0.name.lowercased().contains(lowercased) ||
            $0.host.lowercased().contains(lowercased) ||
            $0.username.lowercased().contains(lowercased) ||
            $0.tags.contains { $0.lowercased().contains(lowercased) }
        }
    }

    // MARK: - Pro Limits

    var canAddServer: Bool {
        if StoreManager.shared.isPro { return true }
        return servers.count < FreeTierLimits.maxServers
    }

    var canAddWorkspace: Bool {
        if StoreManager.shared.isPro { return true }
        return workspaces.count < FreeTierLimits.maxWorkspaces
    }

    var canCreateCustomEnvironment: Bool {
        StoreManager.shared.isPro
    }

    // MARK: - Downgrade Locking
    // When user downgrades from Pro, excess servers/workspaces are locked

    /// Returns sorted servers with oldest (by createdAt) first - these get priority access
    private var serversSortedByCreation: [Server] {
        servers.sorted { $0.createdAt < $1.createdAt }
    }

    /// Returns sorted workspaces with oldest (by order, then createdAt) first
    private var workspacesSortedByOrder: [Workspace] {
        workspaces.sorted { $0.order < $1.order }
    }

    /// Set of server IDs that are accessible on free tier (oldest N servers)
    var unlockedServerIds: Set<UUID> {
        if StoreManager.shared.isPro { return Set(servers.map(\.id)) }
        let unlocked = serversSortedByCreation.prefix(FreeTierLimits.maxServers)
        return Set(unlocked.map(\.id))
    }

    /// Set of workspace IDs that are accessible on free tier (first N workspaces by order)
    var unlockedWorkspaceIds: Set<UUID> {
        if StoreManager.shared.isPro { return Set(workspaces.map(\.id)) }
        let unlocked = workspacesSortedByOrder.prefix(FreeTierLimits.maxWorkspaces)
        return Set(unlocked.map(\.id))
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server) -> Bool {
        if StoreManager.shared.isPro { return false }
        return !unlockedServerIds.contains(server.id)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace) -> Bool {
        if StoreManager.shared.isPro { return false }
        return !unlockedWorkspaceIds.contains(workspace.id)
    }

    /// Number of servers that are locked due to downgrade
    var lockedServersCount: Int {
        if StoreManager.shared.isPro { return 0 }
        return max(0, servers.count - FreeTierLimits.maxServers)
    }

    /// Number of workspaces that are locked due to downgrade
    var lockedWorkspacesCount: Int {
        if StoreManager.shared.isPro { return 0 }
        return max(0, workspaces.count - FreeTierLimits.maxWorkspaces)
    }

    /// Whether user has any locked items after downgrade
    var hasLockedItems: Bool {
        lockedServersCount > 0 || lockedWorkspacesCount > 0
    }

    func createCustomEnvironment(name: String, color: String) throws -> ServerEnvironment {
        guard canCreateCustomEnvironment else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for custom environments"))
        }
        return ServerEnvironment(
            id: UUID(),
            name: name,
            shortName: String(name.prefix(4)),
            colorHex: color,
            isBuiltIn: false
        )
    }

    func updateEnvironment(_ environment: ServerEnvironment, in workspace: Workspace) async throws -> Workspace {
        var updatedWorkspace = workspace
        if let envIndex = updatedWorkspace.environments.firstIndex(where: { $0.id == environment.id }) {
            updatedWorkspace.environments[envIndex] = environment
        } else {
            return updatedWorkspace
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = environment
            try await updateServer(updatedServer)
        }

        return updatedWorkspace
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace
    ) async throws -> Workspace {
        try await deleteEnvironment(environment, in: workspace, fallback: .production)
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace,
        fallback: ServerEnvironment
    ) async throws -> Workspace {
        var updatedWorkspace = workspace
        updatedWorkspace.environments.removeAll { $0.id == environment.id }
        if updatedWorkspace.lastSelectedEnvironmentId == environment.id {
            updatedWorkspace.lastSelectedEnvironmentId = fallback.id
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = fallback
            try await updateServer(updatedServer)
        }

        return updatedWorkspace
    }
}

// MARK: - Free Tier Limits

enum FreeTierLimits {
    static let maxWorkspaces = 1
    static let maxServers = 3
    static let maxTabs = 1
}

// MARK: - VVTerm Error

enum VVTermError: LocalizedError {
    case proRequired(String)
    case serverLocked(String)
    case workspaceLocked(String)
    case connectionFailed(String)
    case authenticationFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .proRequired(let message): return message
        case .serverLocked(let serverName):
            return String(format: String(localized: "Server '%@' is locked"), serverName)
        case .workspaceLocked(let workspaceName):
            return String(format: String(localized: "Workspace '%@' is locked"), workspaceName)
        case .connectionFailed(let message):
            return String(format: String(localized: "Connection failed: %@"), message)
        case .authenticationFailed:
            return String(localized: "Authentication failed")
        case .timeout:
            return String(localized: "Connection timed out")
        }
    }

    var isLockedError: Bool {
        switch self {
        case .serverLocked, .workspaceLocked: return true
        default: return false
        }
    }
}
