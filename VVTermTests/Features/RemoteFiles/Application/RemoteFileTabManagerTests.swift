import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileTabManagerTests {
    @Test
    func closingLastTabPreservesExplicitEmptyState() {
        let defaults = makeDefaults()
        let manager = RemoteFileTabManager(defaults: defaults)
        let server = makeServer()

        let initialTab = manager.ensureInitialTab(
            for: server,
            seedPath: "/srv",
            hasProAccess: false
        )!
        let removedTab = manager.closeTab(initialTab)

        #expect(removedTab == initialTab)
        #expect(manager.tabs(for: server.id).isEmpty)
        #expect(manager.hasInitializedTabs(for: server.id))
        #expect(manager.ensureInitialTab(
            for: server,
            seedPath: "/srv",
            hasProAccess: false
        ) == nil)
    }

    @Test
    func closingSelectedTabPrefersRightNeighborThenLeftNeighbor() throws {
        let defaults = makeDefaults()
        let server = makeServer()
        let firstTab = RemoteFileTab(serverId: server.id, seedPath: "/etc")
        let secondTab = RemoteFileTab(serverId: server.id, seedPath: "/var/log")
        let thirdTab = RemoteFileTab(serverId: server.id, seedPath: "/srv/app")
        let snapshot = RemoteFileTabSnapshot(
            tabsByServer: [server.id.uuidString: [firstTab, secondTab, thirdTab]],
            selectedTabByServer: [server.id.uuidString: secondTab.id]
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "remoteFileTabsSnapshot.v1")

        let manager = RemoteFileTabManager(defaults: defaults)
        let removedMiddle = manager.closeTab(secondTab)

        #expect(removedMiddle == secondTab)
        #expect(manager.selectedTab(for: server.id)?.id == thirdTab.id)

        let removedRightmost = manager.closeTab(thirdTab)

        #expect(removedRightmost == thirdTab)
        #expect(manager.selectedTab(for: server.id)?.id == firstTab.id)
    }

    @Test
    func proAccessFactControlsAdditionalFileTabs() {
        let manager = RemoteFileTabManager(defaults: makeDefaults())
        let server = makeServer()

        #expect(manager.openTab(
            for: server,
            hasProAccess: false
        ) != nil)
        #expect(manager.openTab(
            for: server,
            hasProAccess: false
        ) == nil)
        #expect(manager.openTab(
            for: server,
            hasProAccess: true
        ) != nil)
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Production",
            host: "example.com",
            username: "root"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileTabManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
