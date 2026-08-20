@MainActor
protocol PendingCloudKitMutationHandling: AnyObject {
    func handle(_ mutation: PendingCloudKitMutation) async throws
}
