import Testing
@testable import VVTerm

@MainActor
struct AppLifecycleDependenciesTests {
    @Test
    func routesEachLifecycleActionToItsConfiguredEffect() async {
        var events: [String] = []
        let subscribeToRemoteChanges: @MainActor () async -> Void = {
            events.append("subscribe")
        }
        let refreshNetwork: @MainActor () -> Void = {
            events.append("refresh")
        }
        #if os(iOS)
        let dependencies = AppLifecycleDependencies(
            subscribeToRemoteChanges: subscribeToRemoteChanges,
            refreshNetwork: refreshNetwork,
            endLiveActivitiesForApplicationTermination: {
                events.append("end-live-activities")
                return false
            }
        )
        #else
        let dependencies = AppLifecycleDependencies(
            subscribeToRemoteChanges: subscribeToRemoteChanges,
            refreshNetwork: refreshNetwork
        )
        #endif

        await dependencies.subscribeToRemoteChanges()
        dependencies.refreshNetwork()
        #if os(iOS)
        let didEndLiveActivities = dependencies.endLiveActivitiesForApplicationTermination()
        #expect(!didEndLiveActivities)
        #endif

        #if os(iOS)
        #expect(events == ["subscribe", "refresh", "end-live-activities"])
        #else
        #expect(events == ["subscribe", "refresh"])
        #endif
    }
}
