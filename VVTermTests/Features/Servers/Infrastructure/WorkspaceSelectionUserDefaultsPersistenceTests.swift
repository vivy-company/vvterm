import Foundation
import Testing
@testable import VVTerm

@MainActor
struct WorkspaceSelectionUserDefaultsPersistenceTests {
    @Test
    func liveCompositionUsesOnlyTheInjectedDefaultsOwner() {
        let firstSuite = "WorkspaceSelectionPersistenceTests.owner.first.\(UUID().uuidString)"
        let secondSuite = "WorkspaceSelectionPersistenceTests.owner.second.\(UUID().uuidString)"
        let firstDefaults = makeDefaults(named: firstSuite)
        let secondDefaults = makeDefaults(named: secondSuite)
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }
        let workspace = Workspace(
            id: Self.workspaceID,
            name: "Workspace",
            environments: [.production, .staging]
        )
        let firstStore = WorkspaceSelectionLiveComposition.makeStore(
            defaults: firstDefaults
        )
        let secondStore = WorkspaceSelectionLiveComposition.makeStore(
            defaults: secondDefaults
        )

        firstStore.updateEnvironmentFilterIDs(
            [ServerEnvironment.production.id],
            for: workspace
        )

        #expect(firstStore.environmentFilterIDs(for: workspace) == [ServerEnvironment.production.id])
        #expect(secondStore.environmentFilterIDs(for: workspace).isEmpty)
        #expect(firstDefaults.object(
            forKey: WorkspaceSelectionUserDefaultsPersistence.environmentFiltersKey
        ) != nil)
        #expect(secondDefaults.object(
            forKey: WorkspaceSelectionUserDefaultsPersistence.environmentFiltersKey
        ) == nil)
    }

    @Test
    func readsExistingV2JSONAndWritesCanonicalCompatibleJSON() throws {
        let workspaceID = try #require(UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        ))
        let firstEnvironmentID = try #require(UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"
        ))
        let secondEnvironmentID = try #require(UUID(
            uuidString: "33333333-3333-3333-3333-333333333333"
        ))
        let suiteName = "WorkspaceSelectionPersistenceTests.compatibility"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "{\"\(workspaceID.uuidString)\":[\"\(secondEnvironmentID.uuidString)\",\"\(firstEnvironmentID.uuidString)\"]}",
            forKey: WorkspaceSelectionUserDefaultsPersistence.environmentFiltersKey
        )
        let persistence = WorkspaceSelectionUserDefaultsPersistence(defaults: defaults)

        let loaded = persistence.loadEnvironmentFilters()

        #expect(loaded.filters == WorkspaceEnvironmentFilters(
            selectionsByWorkspace: [
                workspaceID: [firstEnvironmentID, secondEnvironmentID]
            ]
        ))
        #expect(loaded.requiresNormalization)
        #expect(persistence.saveEnvironmentFilters(loaded.filters))
        #expect(defaults.string(
            forKey: WorkspaceSelectionUserDefaultsPersistence.environmentFiltersKey
        ) == "{\"\(workspaceID.uuidString)\":[\"\(firstEnvironmentID.uuidString)\",\"\(secondEnvironmentID.uuidString)\"]}")
    }

    @Test
    func readsLegacyCommaSeparatedIDsAndClearsTheLegacyKey() throws {
        let firstID = try #require(UUID(
            uuidString: "44444444-4444-4444-4444-444444444444"
        ))
        let secondID = try #require(UUID(
            uuidString: "55555555-5555-5555-5555-555555555555"
        ))
        let suiteName = "WorkspaceSelectionPersistenceTests.legacy"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "\(firstID.uuidString),invalid,\(secondID.uuidString)",
            forKey: WorkspaceSelectionUserDefaultsPersistence.legacyEnvironmentFiltersKey
        )
        let persistence = WorkspaceSelectionUserDefaultsPersistence(defaults: defaults)

        let legacy = persistence.loadLegacyEnvironmentFilters()

        #expect(legacy == LegacyWorkspaceEnvironmentFilters(
            selectedIDs: [firstID, secondID],
            hasStoredValue: true
        ))
        persistence.clearLegacyEnvironmentFilters()
        #expect(defaults.object(
            forKey: WorkspaceSelectionUserDefaultsPersistence.legacyEnvironmentFiltersKey
        ) == nil)
    }

    @Test
    func oversizedStoredValuesAreBoundedWithoutReplacingCurrentData() {
        let suiteName = "WorkspaceSelectionPersistenceTests.overflow"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = WorkspaceSelectionUserDefaultsPersistence(defaults: defaults)
        let oversized = String(
            repeating: "x",
            count: WorkspaceSelectionPreferencesCodec.maximumStoredByteCount + 1
        )
        defaults.set(
            oversized,
            forKey: WorkspaceSelectionUserDefaultsPersistence.environmentFiltersKey
        )
        defaults.set(
            oversized,
            forKey: WorkspaceSelectionUserDefaultsPersistence.legacyEnvironmentFiltersKey
        )

        #expect(persistence.loadEnvironmentFilters() == .requiresNormalization(.empty))
        #expect(persistence.loadLegacyEnvironmentFilters() == LegacyWorkspaceEnvironmentFilters(
            selectedIDs: [],
            hasStoredValue: true
        ))

        defaults.set(
            "preserve",
            forKey: WorkspaceSelectionUserDefaultsPersistence.environmentFiltersKey
        )
        let tooManyIDs = Set((0..<2_000).map(Self.deterministicUUID))
        let filters = WorkspaceEnvironmentFilters(
            selectionsByWorkspace: [Self.workspaceID: tooManyIDs]
        )

        #expect(!persistence.saveEnvironmentFilters(filters))
        #expect(defaults.string(
            forKey: WorkspaceSelectionUserDefaultsPersistence.environmentFiltersKey
        ) == "preserve")
    }

    private static let workspaceID = UUID(
        uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    )!

    private static func deterministicUUID(_ value: Int) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0,
            UInt8(value >> 8), UInt8(value & 0xFF)
        ))
    }

    private func makeDefaults(named suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
