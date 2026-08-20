@MainActor
final class StatsPreferencesPendingMutationHandler {
    private let cloud: any StatsPreferencesCloudClient
    private let resolutionPublisher: any StatsPreferencesResolutionPublishing

    init(
        cloud: any StatsPreferencesCloudClient,
        resolutionPublisher: any StatsPreferencesResolutionPublishing
    ) {
        self.cloud = cloud
        self.resolutionPublisher = resolutionPublisher
    }

    func handle(_ preferences: StatsPreferences) async throws {
        let resolvedPreferences = try await cloud.syncStatsPreferences(preferences)
        resolutionPublisher.publishStatsPreferences(resolvedPreferences)
    }
}
