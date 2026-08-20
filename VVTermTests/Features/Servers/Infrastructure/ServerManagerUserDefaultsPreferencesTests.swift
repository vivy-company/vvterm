import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerManagerUserDefaultsPreferencesTests {
    @Test
    func semanticPreferencesRoundTripWithoutExposingKeysToApplication() throws {
        let suiteName = "ServerManagerPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ServerManagerUserDefaultsPreferences(defaults: defaults)
        let pendingWorkspaceID = UUID()

        preferences.didBootstrapDefaultWorkspace = true
        preferences.freePlanGeneration = .legacyThreeServers
        preferences.pendingBootstrapWorkspaceID = pendingWorkspaceID

        #expect(preferences.didBootstrapDefaultWorkspace)
        #expect(preferences.freePlanGeneration == .legacyThreeServers)
        #expect(preferences.pendingBootstrapWorkspaceID == pendingWorkspaceID)

        preferences.freePlanGeneration = nil
        preferences.pendingBootstrapWorkspaceID = nil
        #expect(preferences.freePlanGeneration == nil)
        #expect(preferences.pendingBootstrapWorkspaceID == nil)
    }
}
