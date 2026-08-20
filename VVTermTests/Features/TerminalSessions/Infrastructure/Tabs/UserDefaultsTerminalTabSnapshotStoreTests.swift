import Foundation
import Testing
@testable import VVTerm

@MainActor
struct UserDefaultsTerminalTabSnapshotStoreTests {
    @Test
    func savesLoadsAndRemovesOnlyItsConfiguredSnapshot() {
        let suiteName = "VVTermTests.UserDefaultsTerminalTabSnapshotStore.\(#function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsTerminalTabSnapshotStore(
            defaults: defaults,
            key: "first"
        )
        defaults.set(Data([9]), forKey: "other")

        #expect(store.loadSnapshotData() == nil)

        store.saveSnapshotData(Data([1, 2, 3]))

        #expect(store.loadSnapshotData() == Data([1, 2, 3]))
        #expect(defaults.data(forKey: "other") == Data([9]))

        store.removeSnapshotData()

        #expect(store.loadSnapshotData() == nil)
        #expect(defaults.data(forKey: "other") == Data([9]))
    }
}
