import XCTest
@testable import VVTerm

@MainActor
final class ViewTabConfigurationManagerTests: XCTestCase {
    private let legacyKeys = [
        "connectionViewTabOrder",
        "connectionDefaultViewTab",
        "showStatsTab",
        "showTerminalTab",
        "showFilesTab"
    ]

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "VVTermTests.ViewTabConfiguration.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func persistedConfiguration(in defaults: UserDefaults) throws -> ConnectionViewTabConfiguration {
        let data = try XCTUnwrap(
            defaults.data(forKey: UserDefaultsViewTabConfigurationStore.configurationKey)
        )
        return try JSONDecoder().decode(ConnectionViewTabConfiguration.self, from: data)
    }

    func testHiddenDefaultFallsBackToFirstVisibleTab() {
        let manager = ViewTabConfigurationManager(defaults: makeDefaults())
        manager.setDefaultTab(.terminal)
        manager.setVisibility(for: .terminal, isVisible: false)

        XCTAssertEqual(manager.effectiveDefaultTab(), .stats)
        XCTAssertEqual(manager.configuration.defaultTab, .terminal)
    }

    func testManagerLoadsAndSavesOnlyThroughInjectedPersistence() {
        let initial = ConnectionViewTabConfiguration(
            order: [.files, .terminal, .stats],
            visibleTabs: [.files, .terminal],
            defaultTab: .files
        )
        let persistence = ViewTabConfigurationPersistenceSpy(initial: initial)
        let manager = ViewTabConfigurationManager(persistence: persistence)

        XCTAssertEqual(manager.configuration, initial)

        manager.setVisibility(for: .stats, isVisible: true)

        XCTAssertEqual(persistence.savedConfigurations, [manager.configuration])
    }

    func testInjectedManagersKeepIndependentIdentityAndState() {
        let firstPersistence = ViewTabConfigurationPersistenceSpy(initial: .default)
        let secondInitial = ConnectionViewTabConfiguration(
            order: [.files, .terminal, .stats],
            visibleTabs: [.files, .terminal],
            defaultTab: .files
        )
        let secondPersistence = ViewTabConfigurationPersistenceSpy(initial: secondInitial)
        let first = ViewTabConfigurationManager(persistence: firstPersistence)
        let second = ViewTabConfigurationManager(persistence: secondPersistence)

        first.setDefaultTab(.terminal)
        first.setVisibility(for: .files, isVisible: false)

        XCTAssertFalse(first === second)
        XCTAssertEqual(second.configuration, secondInitial)
        XCTAssertTrue(secondPersistence.savedConfigurations.isEmpty)
    }

    func testCannotHideLastVisibleTab() {
        let manager = ViewTabConfigurationManager(defaults: makeDefaults())
        manager.setVisibility(for: .terminal, isVisible: false)
        manager.setVisibility(for: .files, isVisible: false)
        manager.setVisibility(for: .stats, isVisible: false)

        XCTAssertTrue(manager.isTabVisible(.stats))
        XCTAssertEqual(manager.currentVisibleTabs, [.stats])
    }

    func testLegacyKeysMigrateToOneConfigurationSnapshotAndAreRemoved() throws {
        let defaults = makeDefaults()
        defaults.set(
            try JSONEncoder().encode(["files", "unknown", "files", "stats"]),
            forKey: "connectionViewTabOrder"
        )
        defaults.set("terminal", forKey: "connectionDefaultViewTab")
        defaults.set(false, forKey: "showStatsTab")
        defaults.set(true, forKey: "showTerminalTab")
        defaults.set(false, forKey: "showFilesTab")

        let manager = ViewTabConfigurationManager(defaults: defaults)

        XCTAssertEqual(manager.tabOrder, [.files, .stats, .terminal])
        XCTAssertEqual(manager.configuration.visibleTabs, [.terminal])
        XCTAssertEqual(manager.configuration.defaultTab, .terminal)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)
        for key in legacyKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testStoredConfigurationWinsOverStaleLegacyKeys() throws {
        let defaults = makeDefaults()
        let storedConfiguration = ConnectionViewTabConfiguration(
            order: [.terminal, .files, .stats],
            visibleTabs: [.terminal, .files],
            defaultTab: .files
        )
        defaults.set(
            try JSONEncoder().encode(storedConfiguration),
            forKey: UserDefaultsViewTabConfigurationStore.configurationKey
        )
        defaults.set("stats", forKey: "connectionDefaultViewTab")
        defaults.set(false, forKey: "showFilesTab")

        let manager = ViewTabConfigurationManager(defaults: defaults)

        XCTAssertEqual(manager.configuration, storedConfiguration)
        for key in legacyKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testEachMutationPersistsTheCompleteConfiguration() throws {
        let defaults = makeDefaults()
        let manager = ViewTabConfigurationManager(defaults: defaults)

        manager.setDefaultTab(.files)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)

        manager.setVisibility(for: .stats, isVisible: false)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)

        manager.moveTab(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)

        let storedConfiguration = try persistedConfiguration(in: defaults)
        XCTAssertEqual(storedConfiguration, manager.configuration)
        XCTAssertEqual(storedConfiguration.order, [.files, .stats, .terminal])
        XCTAssertEqual(storedConfiguration.visibleTabs, [.terminal, .files])
        XCTAssertEqual(storedConfiguration.defaultTab, .files)
    }

    func testMovingMultipleTabsPreservesSourceOrderAtAdjustedDestination() {
        let manager = ViewTabConfigurationManager(defaults: makeDefaults())

        manager.moveTab(from: IndexSet([0, 2]), to: 3)

        XCTAssertEqual(manager.tabOrder, [.terminal, .stats, .files])
    }

    func testResetPersistsOnlyTheDefaultConfigurationSnapshot() throws {
        let defaults = makeDefaults()
        let manager = ViewTabConfigurationManager(defaults: defaults)
        manager.setDefaultTab(.files)
        manager.setVisibility(for: .stats, isVisible: false)

        manager.resetToDefaults()

        XCTAssertEqual(try persistedConfiguration(in: defaults), .default)
        for key in legacyKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }
}

@MainActor
private final class ViewTabConfigurationPersistenceSpy: ConnectionViewTabConfigurationPersisting {
    private let initial: ConnectionViewTabConfiguration
    private(set) var savedConfigurations: [ConnectionViewTabConfiguration] = []

    init(initial: ConnectionViewTabConfiguration) {
        self.initial = initial
    }

    func load() -> ConnectionViewTabConfiguration {
        initial
    }

    func save(_ configuration: ConnectionViewTabConfiguration) {
        savedConfigurations.append(configuration)
    }
}
