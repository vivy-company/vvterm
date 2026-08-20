import Foundation
import Testing
@testable import VVTerm

@MainActor
struct LocalDeviceDiscoveryPresentationTests {
    @Test
    func factoryCreatesOneStableManagerForEachPresentation() {
        var creationCount = 0
        let service = LocalDeviceDiscoveryServiceFake()
        let factory: LocalSSHDiscoveryManagerFactory = {
            creationCount += 1
            return LocalSSHDiscoveryManager(
                dependencies: LocalSSHDiscoveryDependencies(
                    service: service,
                    networkAvailability: { .supported },
                    makeScanID: UUID.init
                )
            )
        }

        let first = LocalDeviceDiscoveryPresentation(makeManager: factory)
        let firstManager = first.manager

        #expect(creationCount == 1)
        #expect(first.manager === firstManager)

        let second = LocalDeviceDiscoveryPresentation(makeManager: factory)

        #expect(creationCount == 2)
        #expect(second.manager !== firstManager)
        #expect(second.id != first.id)
        #expect(service.startCount == 0)
    }
}

@MainActor
private final class LocalDeviceDiscoveryServiceFake: LocalSSHDiscovering {
    private(set) var startCount = 0

    var ownerReleaseStopRequest: LocalSSHDiscoveryStopRequest {
        LocalSSHDiscoveryStopRequest(stop: {})
    }

    func startScan() -> AsyncStream<LocalSSHDiscoveryEvent> {
        startCount += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stopScan() {}
}
