import Combine
import Foundation

@MainActor
final class RemoteFileTabManager: ObservableObject {
    @Published private(set) var tabsByServer: [UUID: [RemoteFileTab]] = [:] {
        didSet { persistSnapshotIfNeeded() }
    }
    @Published private(set) var selectedTabByServer: [UUID: UUID] = [:] {
        didSet { persistSnapshotIfNeeded() }
    }

    private let defaults: UserDefaults
    private let persistenceKey = "remoteFileTabsSnapshot.v1"
    private var isRestoring = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreSnapshot()
    }

    func tabs(for serverId: UUID) -> [RemoteFileTab] {
        tabsByServer[serverId] ?? []
    }

    func selectedTab(for serverId: UUID) -> RemoteFileTab? {
        let serverTabs = tabs(for: serverId)
        guard !serverTabs.isEmpty else { return nil }

        if let selectedId = selectedTabByServer[serverId],
           let selectedTab = serverTabs.first(where: { $0.id == selectedId }) {
            return selectedTab
        }

        return serverTabs.first
    }

    func hasInitializedTabs(for serverId: UUID) -> Bool {
        tabsByServer[serverId] != nil
    }

    func canOpenNewTab(for serverId: UUID, hasProAccess: Bool) -> Bool {
        if hasProAccess {
            return true
        }

        return tabs(for: serverId).count < FreeTierLimits.maxTabs
    }

    @discardableResult
    func ensureInitialTab(
        for server: Server,
        seedPath: String? = nil,
        hasProAccess: Bool
    ) -> RemoteFileTab? {
        if let existingTabs = tabsByServer[server.id] {
            guard !existingTabs.isEmpty else { return nil }
            if let selectedTab = selectedTab(for: server.id) {
                return selectedTab
            }

            let fallbackTab = existingTabs.first
            selectedTabByServer[server.id] = fallbackTab?.id
            return fallbackTab
        }

        return openTab(
            for: server,
            seedPath: seedPath,
            hasProAccess: hasProAccess
        )
    }

    @discardableResult
    func openTab(
        for server: Server,
        seedPath: String? = nil,
        hasProAccess: Bool
    ) -> RemoteFileTab? {
        guard canOpenNewTab(for: server.id, hasProAccess: hasProAccess) else { return nil }

        let tab = RemoteFileTab(serverId: server.id, seedPath: seedPath)
        var serverTabs = tabsByServer[server.id] ?? []
        serverTabs.append(tab)
        setTabs(serverTabs, for: server.id, preferredSelectedTabId: tab.id)
        return tab
    }

    @discardableResult
    func duplicateTab(
        _ tab: RemoteFileTab,
        seedPath: String? = nil,
        hasProAccess: Bool
    ) -> RemoteFileTab? {
        guard canOpenNewTab(for: tab.serverId, hasProAccess: hasProAccess) else { return nil }

        let duplicate = RemoteFileTab(
            serverId: tab.serverId,
            seedPath: seedPath ?? tab.lastKnownPath ?? tab.seedPath,
            lastKnownPath: seedPath ?? tab.lastKnownPath ?? tab.seedPath
        )
        var serverTabs = tabsByServer[tab.serverId] ?? []
        serverTabs.append(duplicate)
        setTabs(serverTabs, for: tab.serverId, preferredSelectedTabId: duplicate.id)
        return duplicate
    }

    func selectTab(_ tab: RemoteFileTab) {
        guard tabs(for: tab.serverId).contains(where: { $0.id == tab.id }) else { return }
        selectedTabByServer[tab.serverId] = tab.id
    }

    @discardableResult
    func closeTab(_ tab: RemoteFileTab) -> RemoteFileTab? {
        guard var serverTabs = tabsByServer[tab.serverId],
              let index = serverTabs.firstIndex(where: { $0.id == tab.id }) else {
            return nil
        }

        let removedTab = serverTabs.remove(at: index)
        let preferredSelectedTabId: UUID?

        if selectedTabByServer[tab.serverId] == tab.id {
            if index < serverTabs.count {
                preferredSelectedTabId = serverTabs[index].id
            } else {
                preferredSelectedTabId = serverTabs.last?.id
            }
        } else {
            preferredSelectedTabId = selectedTabByServer[tab.serverId]
        }

        setTabs(serverTabs, for: tab.serverId, preferredSelectedTabId: preferredSelectedTabId)
        return removedTab
    }

    @discardableResult
    func closeOtherTabs(except tab: RemoteFileTab) -> [RemoteFileTab] {
        let serverTabs = tabs(for: tab.serverId)
        let removedTabs = serverTabs.filter { $0.id != tab.id }
        guard !removedTabs.isEmpty else { return [] }

        setTabs(serverTabs.filter { $0.id == tab.id }, for: tab.serverId, preferredSelectedTabId: tab.id)
        return removedTabs
    }

    @discardableResult
    func closeTabsToLeft(of tab: RemoteFileTab) -> [RemoteFileTab] {
        guard let index = tabs(for: tab.serverId).firstIndex(where: { $0.id == tab.id }),
              index > 0 else {
            return []
        }

        let serverTabs = tabs(for: tab.serverId)
        let removedTabs = Array(serverTabs[..<index])
        let remainingTabs = Array(serverTabs[index...])
        let preferredSelectedTabId = preferredSelectedTabId(afterRemoving: removedTabs, in: tab.serverId, fallback: tab.id)
        setTabs(remainingTabs, for: tab.serverId, preferredSelectedTabId: preferredSelectedTabId)
        return removedTabs
    }

    @discardableResult
    func closeTabsToRight(of tab: RemoteFileTab) -> [RemoteFileTab] {
        let serverTabs = tabs(for: tab.serverId)
        guard let index = serverTabs.firstIndex(where: { $0.id == tab.id }),
              index < serverTabs.count - 1 else {
            return []
        }

        let removedTabs = Array(serverTabs[(index + 1)...])
        let remainingTabs = Array(serverTabs[...index])
        let preferredSelectedTabId = preferredSelectedTabId(afterRemoving: removedTabs, in: tab.serverId, fallback: tab.id)
        setTabs(remainingTabs, for: tab.serverId, preferredSelectedTabId: preferredSelectedTabId)
        return removedTabs
    }

    func selectNextTab(for serverId: UUID) {
        let serverTabs = tabs(for: serverId)
        guard serverTabs.count > 1 else { return }

        let currentIndex = currentTabIndex(for: serverId, in: serverTabs)
        guard currentIndex < serverTabs.count - 1 else { return }
        selectedTabByServer[serverId] = serverTabs[currentIndex + 1].id
    }

    func selectPreviousTab(for serverId: UUID) {
        let serverTabs = tabs(for: serverId)
        guard serverTabs.count > 1 else { return }

        let currentIndex = currentTabIndex(for: serverId, in: serverTabs)
        guard currentIndex > 0 else { return }
        selectedTabByServer[serverId] = serverTabs[currentIndex - 1].id
    }

    func updateLastKnownPath(_ path: String?, for tabId: UUID) {
        guard let path else { return }

        for (serverId, serverTabs) in tabsByServer {
            guard let index = serverTabs.firstIndex(where: { $0.id == tabId }) else { continue }

            let normalizedPath = RemoteFilePath.normalize(path)
            guard serverTabs[index].lastKnownPath != normalizedPath else { return }

            var updatedTabs = serverTabs
            updatedTabs[index].updateLastKnownPath(normalizedPath)
            tabsByServer[serverId] = updatedTabs
            return
        }
    }

    func disconnect(serverId: UUID) {
        tabsByServer.removeValue(forKey: serverId)
        selectedTabByServer.removeValue(forKey: serverId)
    }

    private func currentTabIndex(for serverId: UUID, in serverTabs: [RemoteFileTab]) -> Int {
        guard let selectedId = selectedTabByServer[serverId],
              let index = serverTabs.firstIndex(where: { $0.id == selectedId }) else {
            return 0
        }

        return index
    }

    private func preferredSelectedTabId(
        afterRemoving removedTabs: [RemoteFileTab],
        in serverId: UUID,
        fallback: UUID?
    ) -> UUID? {
        let removedIDs = Set(removedTabs.map(\.id))
        if let selectedId = selectedTabByServer[serverId], !removedIDs.contains(selectedId) {
            return selectedId
        }
        return fallback
    }

    private func setTabs(_ tabs: [RemoteFileTab], for serverId: UUID, preferredSelectedTabId: UUID?) {
        tabsByServer[serverId] = tabs

        guard !tabs.isEmpty else {
            selectedTabByServer.removeValue(forKey: serverId)
            return
        }

        if let preferredSelectedTabId,
           tabs.contains(where: { $0.id == preferredSelectedTabId }) {
            selectedTabByServer[serverId] = preferredSelectedTabId
            return
        }

        if let currentSelectedId = selectedTabByServer[serverId],
           tabs.contains(where: { $0.id == currentSelectedId }) {
            return
        }

        selectedTabByServer[serverId] = tabs.first?.id
    }

    private func persistSnapshotIfNeeded() {
        guard !isRestoring else { return }
        persistSnapshot()
    }

    private func persistSnapshot() {
        let snapshot = RemoteFileTabSnapshot(
            tabsByServer: Dictionary(
                uniqueKeysWithValues: tabsByServer.map { serverId, tabs in
                    (serverId.uuidString, tabs)
                }
            ),
            selectedTabByServer: Dictionary(
                uniqueKeysWithValues: selectedTabByServer.map { serverId, tabId in
                    (serverId.uuidString, tabId)
                }
            )
        )

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func restoreSnapshot() {
        guard let data = defaults.data(forKey: persistenceKey),
              let snapshot = try? JSONDecoder().decode(RemoteFileTabSnapshot.self, from: data),
              snapshot.schemaVersion == RemoteFileTabSnapshot.currentSchemaVersion else {
            tabsByServer = [:]
            selectedTabByServer = [:]
            return
        }

        isRestoring = true

        var restoredTabsByServer: [UUID: [RemoteFileTab]] = [:]
        for (serverIdString, tabs) in snapshot.tabsByServer {
            guard let serverId = UUID(uuidString: serverIdString) else { continue }
            restoredTabsByServer[serverId] = tabs.filter { $0.serverId == serverId }
        }

        var restoredSelectedTabByServer: [UUID: UUID] = [:]
        for (serverIdString, selectedTabId) in snapshot.selectedTabByServer {
            guard let serverId = UUID(uuidString: serverIdString),
                  let tabs = restoredTabsByServer[serverId],
                  tabs.contains(where: { $0.id == selectedTabId }) else {
                continue
            }

            restoredSelectedTabByServer[serverId] = selectedTabId
        }

        tabsByServer = restoredTabsByServer
        selectedTabByServer = restoredSelectedTabByServer
        isRestoring = false
    }
}
