import SwiftUI

struct SettingsView: View {
    let statsPreferencesStore: PreferencesStore
    let voiceModelManagers: VoiceSettingsModelManagerOwner
    let analyticsOptOutAction: AnalyticsOptOutAction

    @AppStorage(TerminalDefaults.fontNameKey) var terminalFontName = TerminalDefaults.defaultFontName
    @AppStorage(TerminalDefaults.fontSizeKey) var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(SettingsRoutePersistence.selectedRouteKey)
    var selectedRouteRaw = SettingsRoute.defaultRoute.rawValue
    @State var searchText = ""

    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        platformBody
    }

    var selectedRoute: SettingsRoute {
        SettingsRoutePersistence.route(for: selectedRouteRaw)
    }

    func visibleRoutes(in group: SettingsGroup) -> [SettingsRoute] {
        SettingsRouteCatalog.visibleRoutes(
            from: SettingsRouteCatalog.routes(in: group),
            matching: searchText
        )
    }

    func visibleRoutes(from routes: [SettingsRoute]) -> [SettingsRoute] {
        SettingsRouteCatalog.visibleRoutes(from: routes, matching: searchText)
    }

    var visibleDetailRoute: SettingsRoute? {
        SettingsRouteCatalog.visibleDetailRoute(
            selectedRoute: selectedRoute,
            matching: searchText
        )
    }

    @ViewBuilder
    func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .pro:
            ProSettingsView()
        case .appearanceAndLanguage:
            AppearanceLanguageSettingsView()
        case .navigationAndStats:
            NavigationStatsSettingsView(statsPreferencesStore: statsPreferencesStore)
        case .privacyAndAppLock:
            PrivacyAppLockSettingsView(analyticsOptOutAction: analyticsOptOutAction)
        case .terminalAppearance:
            TerminalAppearanceSettingsView(fontName: $terminalFontName, fontSize: $terminalFontSize)
        case .keyboardAndInput:
            TerminalKeyboardInputSettingsView()
        case .sessionsAndConnections:
            TerminalSessionsConnectionsSettingsView()
        case .clipboardAndPaste:
            TerminalClipboardPasteSettingsView()
        case .sshKeys:
            KeychainSettingsView()
        case .trustedHosts:
            TrustedHostsSettingsView()
        case .iCloudSync:
            SyncSettingsView()
        case .transcription:
            TranscriptionSettingsView(modelManagers: voiceModelManagers)
        case .aboutAndSupport:
            AboutSettingsView()
        }
    }

    @ViewBuilder
    func routeLabel(for route: SettingsRoute) -> some View {
        HStack(spacing: 10) {
            Label(route.title, systemImage: route.icon)
            Spacer(minLength: 8)
            if route == .pro {
                Text(storeStatusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(storeManager.accessState == .pro ? .green : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vvterm.settings.route.\(route.rawValue)")
    }

    var storeStatusLabel: String {
        switch storeManager.accessState {
        case .checking:
            String(localized: "Checking...")
        case .free:
            String(localized: "FREE_PLAN")
        case .pro:
            String(localized: "PRO")
        }
    }
}
