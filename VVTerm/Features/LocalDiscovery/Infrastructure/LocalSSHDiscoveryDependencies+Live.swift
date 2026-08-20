import Foundation

extension LocalSSHDiscoveryService: LocalSSHDiscovering {}

extension LocalSSHDiscoveryDependencies {
    static func live(
        networkConnectionType: @escaping () -> NetworkMonitor.ConnectionType,
        makeScanID: @escaping () -> UUID
    ) -> Self {
        LocalSSHDiscoveryDependencies(
            service: LocalSSHDiscoveryService(),
            networkAvailability: {
                networkConnectionType() == .cellular
                    ? .unsupported
                    : .supported
            },
            makeScanID: makeScanID
        )
    }
}
