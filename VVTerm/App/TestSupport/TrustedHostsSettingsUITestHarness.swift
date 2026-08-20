#if DEBUG
import Foundation
import SwiftUI

@MainActor
private final class TrustedHostsSettingsUITestRepository: KnownHostSettingsRepository {
    private var knownHosts = [
        KnownHostSettingsItem(
            host: "trusted.example.com",
            port: 22,
            lastSeenAt: Date(timeIntervalSince1970: 1_577_934_245)
        ),
        KnownHostSettingsItem(
            host: "second.example.com",
            port: 2222,
            lastSeenAt: Date(timeIntervalSince1970: 1_609_459_200)
        ),
    ]

    func loadKnownHosts() -> [KnownHostSettingsItem] {
        knownHosts
    }

    func removeKnownHost(host: String, port: Int) {
        knownHosts.removeAll { $0.host == host && $0.port == port }
    }

    func removeAllKnownHosts() {
        knownHosts.removeAll()
    }
}

struct TrustedHostsSettingsUITestHarness: View {
    @StateObject private var coordinator = KnownHostSettingsCoordinator(
        repository: TrustedHostsSettingsUITestRepository()
    )

    var body: some View {
        NavigationStack {
            TrustedHostsSettingsView()
                .navigationTitle("Trusted Hosts")
        }
        .environmentObject(coordinator)
        .accessibilityIdentifier("vvterm.trustedHostsSettingsTest.root")
    }
}
#endif
