import Foundation
import Testing
@testable import VVTerm

@Suite("Settings route catalog")
@MainActor
struct SettingsRouteCatalogTests {
    @Test("Catalog follows the approved grouped order")
    func approvedGroupedOrder() {
        #expect(SettingsRoute.defaultRoute == .appearanceAndLanguage)
        #expect(SettingsRoute.defaultRoute != .pro)
        #expect(SettingsRouteCatalog.leadingRoutes == [.pro])
        #expect(SettingsRouteCatalog.groups == [
            .general,
            .terminal,
            .connections,
            .privacyAndData,
        ])
        #expect(SettingsRouteCatalog.routes(in: .general) == [
            .appearanceAndLanguage,
            .navigationAndStats,
        ])
        #expect(SettingsRouteCatalog.routes(in: .terminal) == [
            .terminalAppearance,
            .keyboardAndInput,
            .transcription,
            .clipboardAndPaste,
        ])
        #expect(SettingsRouteCatalog.routes(in: .connections) == [
            .sessionsAndConnections,
            .sshKeys,
            .trustedHosts,
        ])
        #expect(SettingsRouteCatalog.routes(in: .privacyAndData) == [
            .privacyAndAppLock,
            .iCloudSync,
        ])
        #expect(SettingsRouteCatalog.trailingRoutes == [.aboutAndSupport])
    }

    @Test("Search finds page titles, labels, and common terms", arguments: [
        ("cursor", SettingsRoute.terminalAppearance),
        ("tmux", SettingsRoute.sessionsAndConnections),
        ("analytics", SettingsRoute.privacyAndAppLock),
        ("fingerprint", SettingsRoute.trustedHosts),
        ("keyboard", SettingsRoute.keyboardAndInput),
    ])
    func search(query: String, expectedRoute: SettingsRoute) {
        #expect(SettingsRouteCatalog.routes(matching: query).contains(expectedRoute))
    }

    @Test("Search includes localized setting labels")
    func localizedSearchTerms() {
        #expect(
            SettingsRouteCatalog.routes(matching: "Option als Alt")
                .contains(.keyboardAndInput)
        )
    }

    @Test("A filtered-out macOS selection has no visible detail route")
    func filteredSelection() {
        #expect(
            SettingsRouteCatalog.visibleDetailRoute(
                selectedRoute: .terminalAppearance,
                matching: "tmux"
            ) == nil
        )
        #expect(
            SettingsRouteCatalog.visibleDetailRoute(
                selectedRoute: .sessionsAndConnections,
                matching: "tmux"
            ) == .sessionsAndConnections
        )
    }

    @Test("Empty search returns every route")
    func emptySearch() {
        #expect(SettingsRouteCatalog.routes(matching: "  ") == SettingsRoute.allCases)
    }
}

@Suite("Settings route persistence")
struct SettingsRoutePersistenceTests {
    @Test("Selection round-trips through the existing defaults store")
    func selectionRoundTrip() throws {
        let suiteName = "SettingsRoutePersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsRoutePersistence.load(from: defaults) == .appearanceAndLanguage)

        SettingsRoutePersistence.save(.clipboardAndPaste, to: defaults)

        #expect(SettingsRoutePersistence.load(from: defaults) == .clipboardAndPaste)
    }

    @Test("Unknown persisted values use the stable default page")
    func unknownValueFallback() {
        #expect(SettingsRoutePersistence.route(for: "removed-route") == .appearanceAndLanguage)
    }
}
