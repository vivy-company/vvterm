import Foundation
import Testing
@testable import VVTerm

@MainActor
struct LocalSSHDiscoveryStatusPresentationTests {
    @Test
    func mapsEveryStatusPhaseAndScanningSourceCombination() {
        let scanID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let noSources = LocalSSHDiscoveryState.Scan(id: scanID)
        var bonjour = noSources
        bonjour.activeSources = [.bonjour]
        var probe = noSources
        probe.activeSources = [.probe]
        var allSources = noSources
        allSources.activeSources = [.bonjour, .probe]

        let mappings: [(LocalSSHDiscoveryState.Phase, Int, String)] = [
            (.idle, 0, String(localized: "Ready to scan your local network.")),
            (
                .unsupportedNetwork,
                0,
                String(localized: "Connect to Wi-Fi or ethernet to discover local SSH hosts.")
            ),
            (.scanning(noSources), 0, String(localized: "Scanning...")),
            (.scanning(bonjour), 0, String(localized: "Scanning Bonjour services...")),
            (
                .scanning(probe),
                0,
                String(localized: "Scanning local subnet for SSH port 22...")
            ),
            (
                .scanning(allSources),
                0,
                String(localized: "Scanning with Bonjour and SSH port probe...")
            ),
            (.completed(.unknown), 0, String(localized: "No SSH hosts found.")),
            (
                .completed(.granted),
                2,
                String(
                    format: String(localized: "%lld SSH host(s) found."),
                    Int64(2)
                )
            )
        ]

        for (phase, hostCount, expected) in mappings {
            #expect(
                LocalSSHDiscoveryStatusText.text(
                    for: phase,
                    hostCount: hostCount
                ) == expected
            )
        }
    }
}
