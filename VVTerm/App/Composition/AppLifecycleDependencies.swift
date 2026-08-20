@MainActor
struct AppLifecycleDependencies {
    let subscribeToRemoteChanges: @MainActor () async -> Void
    let refreshNetwork: @MainActor () -> Void

    #if os(iOS)
    let endLiveActivitiesForApplicationTermination: @MainActor () -> Bool
    #endif
}
