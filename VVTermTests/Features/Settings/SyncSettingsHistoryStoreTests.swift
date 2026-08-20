import Foundation
import Testing
@testable import VVTerm

@MainActor
struct SyncSettingsHistoryStoreTests {
    @Test
    func successfulSyncDatePersistsAcrossStoreInstances() throws {
        let suiteName = "SyncSettingsHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = Date(timeIntervalSince1970: 1_725_000_000)

        try UserDefaultsSyncSettingsHistoryStore(defaults: defaults)
            .recordSuccessfulSync(at: date)

        let reloaded = UserDefaultsSyncSettingsHistoryStore(defaults: defaults)
        #expect(reloaded.lastSuccessfulSyncDate == date)
    }
}
