@MainActor
final class TerminalAccessoryPendingMutationHandler {
    private let cloud: any TerminalAccessoryCloudClient
    private let resolutionPublisher: any TerminalAccessoryResolutionPublishing

    init(
        cloud: any TerminalAccessoryCloudClient,
        resolutionPublisher: any TerminalAccessoryResolutionPublishing
    ) {
        self.cloud = cloud
        self.resolutionPublisher = resolutionPublisher
    }

    func handle(_ profile: TerminalAccessoryProfile) async throws {
        let resolvedProfile = try await cloud.syncTerminalAccessoryProfile(profile)
        resolutionPublisher.publishTerminalAccessoryProfile(resolvedProfile)
    }
}
