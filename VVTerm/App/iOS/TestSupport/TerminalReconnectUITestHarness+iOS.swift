#if os(iOS) && DEBUG
import SwiftUI
import UIKit

/// Boots the production server route against a loopback SSH fixture. Only the
/// app's root data is seeded here; terminal, reconnect, responder, and SSH work
/// all run through the same types used by the normal iOS route.
struct TerminalReconnectUITestHarness: View {
    private enum FixtureState {
        case preparing
        case ready(Server)
        case failed(String)
    }

    private enum FixtureError: LocalizedError {
        case missingUsername
        case invalidPrivateKey

        var errorDescription: String? {
            switch self {
            case .missingUsername:
                "Missing loopback SSH username"
            case .invalidPrivateKey:
                "Invalid loopback SSH private key"
            }
        }
    }

    private static let serverId = UUID(uuidString: "D3A03FD5-453E-43AC-8BB5-838E5D5D1990")!
    private static let workspaceId = UUID(uuidString: "B51203C0-15B5-47E3-9322-D4D7E8A51990")!
    private static let sshHost = "127.0.0.1"
    private static let sshPort = 22_229
    private static let fixtureDefaults = UserDefaults(suiteName: "app.vivy.vvterm.dev199-ui-test")!
    private static let fixturePrivateKeyDefaultsKey = "sshPrivateKeyBase64"
    private static let fixtureUsernameDefaultsKey = "sshUsername"

    private let tabManager: TerminalTabManager
    @ObservedObject private var serverManager: ServerManager
    @ObservedObject private var engagementTracker: EngagementTracker
    private let statsDependencies: ServerStatsScreenDependencies
    private let terminalSecurityActions: TerminalSecurityActions
    private let serverFormDependencies: ServerFormDependencies
    private let voiceModelManagers: VoiceSettingsModelManagerOwner
    private let voiceInputRuntimeStore: VoiceInputRuntimeStore
    private let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    private let analyticsOptOutAction = AnalyticsOptOutAction(emitAnalyticsDisabled: {})
    @StateObject private var fileTabs: RemoteFileTabManager
    @ObservedObject private var fileBrowser: RemoteFileBrowserStore
    @State private var fixtureState = FixtureState.preparing

    init(
        tabManager: TerminalTabManager,
        serverManager: ServerManager,
        fileBrowser: RemoteFileBrowserStore,
        engagementTracker: EngagementTracker,
        statsDependencies: ServerStatsScreenDependencies,
        terminalSecurityActions: TerminalSecurityActions,
        serverFormDependencies: ServerFormDependencies,
        voiceModelManagers: VoiceSettingsModelManagerOwner,
        voiceInputRuntimeStore: VoiceInputRuntimeStore,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory
    ) {
        self.tabManager = tabManager
        _serverManager = ObservedObject(wrappedValue: serverManager)
        _fileBrowser = ObservedObject(wrappedValue: fileBrowser)
        _engagementTracker = ObservedObject(wrappedValue: engagementTracker)
        self.statsDependencies = statsDependencies
        self.terminalSecurityActions = terminalSecurityActions
        self.serverFormDependencies = serverFormDependencies
        self.voiceModelManagers = voiceModelManagers
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        _fileTabs = StateObject(
            wrappedValue: RemoteFileTabManager(defaults: Self.fixtureDefaults)
        )
    }

    var body: some View {
        fixtureContent
            .overlay(alignment: .topLeading) {
                TerminalReconnectDiagnosticsLabel(
                    tabManager: tabManager,
                    serverId: activeServer?.id,
                    fallback: fixtureDiagnosticFallback
                )
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if exposesKeyboardLossControl {
                    HStack(spacing: 6) {
                        Button("Lose Input") {
                            beginUnexpectedKeyboardLoss()
                        }
                        .accessibilityIdentifier("vvterm.reconnectTest.keyboard.unexpectedLoss")

                        if simulatesKeyboardFrames {
                            Button("Stale Find Frame") {
                                simulateVisibleFindKeyboardFrame()
                            }
                            .accessibilityIdentifier("vvterm.reconnectTest.keyboard.staleFindFrame")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 140)
                    .padding(.leading, 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if usesNavigationHarness, activeServer != nil {
                    Button("Toggle Servers") {
                        toggleServerMetadata()
                    }
                    .accessibilityIdentifier(
                        "vvterm.navigationTest.toggleServerMetadata"
                    )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 140)
                    .padding(.trailing, 8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if usesColdRelaunchHarness {
                    Text(coldRelaunchDiagnostics)
                        .font(.caption2.monospaced())
                        .accessibilityIdentifier("vvterm.coldRelaunchTest.diagnostics")
                        .padding(6)
                }
            }
            .task {
                await prepareFixture()
            }
    }

    @ViewBuilder
    private var fixtureContent: some View {
        switch fixtureState {
        case .preparing:
            ProgressView()
        case .ready(let server):
            if usesNavigationHarness {
                iOSContentView(
                    serverManager: serverManager,
                    engagementTracker: engagementTracker,
                    tabManager: tabManager,
                    fileTabs: fileTabs,
                    fileBrowser: fileBrowser,
                    statsDependencies: statsDependencies,
                    terminalSecurityActions: terminalSecurityActions,
                    serverFormDependencies: serverFormDependencies,
                    voiceModelManagers: voiceModelManagers,
                    voiceInputRuntimeStore: voiceInputRuntimeStore,
                    makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                    analyticsOptOutAction: analyticsOptOutAction
                )
            } else {
                NavigationStack {
                    ServerTerminalRoute(
                        tabManager: tabManager,
                        serverManager: serverManager,
                        fileTabs: fileTabs,
                        fileBrowser: fileBrowser,
                        statsDependencies: statsDependencies,
                        terminalSecurityActions: terminalSecurityActions,
                        serverFormDependencies: serverFormDependencies,
                        voiceModelManagers: voiceModelManagers,
                        voiceInputRuntimeStore: voiceInputRuntimeStore,
                        analyticsOptOutAction: analyticsOptOutAction,
                        route: .active(serverId: server.id),
                        makeLocalDiscoveryManager: makeLocalDiscoveryManager,
                        onBack: {}
                    )
                }
            }
        case .failed(let message):
            Text(message)
        }
    }

    private var activeServer: Server? {
        guard case .ready(let server) = fixtureState else { return nil }
        return server
    }

    private var exposesKeyboardLossControl: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-unexpected-keyboard-loss-control"
        )
    }

    private var simulatesKeyboardFrames: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-simulate-keyboard-frames"
        )
    }

    private var usesNavigationHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-server-navigation"
        )
    }

    private var usesColdRelaunchHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-cold-relaunch"
        )
    }

    private var seedsColdRelaunchHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-seed-cold-relaunch"
        )
    }

    private var coldRelaunchDiagnostics: String {
        guard let serverId = activeServer?.id else { return "setup=preparing" }
        let tabs = tabManager.sessionState.tabs(for: serverId)
        let paneCount = tabs.reduce(0) { $0 + $1.paneCount }
        let selected = tabManager.sessionState.selectedTabId(for: serverId)?.uuidString ?? "none"
        let focused = tabManager.sessionState.selectedTab(for: serverId)?.focusedPaneId.uuidString ?? "none"
        let disconnected = tabs.flatMap(\.allPaneIds).filter {
            tabManager.sessionState.paneState(for: $0)?.connectionState == .disconnected
        }.count
        return "setup=ready tabs=\(tabs.count) panes=\(paneCount) selected=\(selected) focused=\(focused) disconnected=\(disconnected)"
    }

    private var focusedTerminal: GhosttyTerminalView? {
        guard let serverId = activeServer?.id,
              let paneId = tabManager.sessionState.selectedTab(for: serverId)?.focusedPaneId else {
            return nil
        }
        return tabManager.terminalSurfaceStore.ghosttySurface(for: paneId)
    }

    private func beginUnexpectedKeyboardLoss() {
        focusedTerminal?.keyboardUITestBeginUnexpectedSoftwareKeyboardLoss()
        if simulatesKeyboardFrames {
            tabManager.keyboardCoordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
        }
    }

    private func simulateVisibleFindKeyboardFrame() {
        guard simulatesKeyboardFrames,
              let focusedTerminal,
              let frame = terminalReconnectVisibleKeyboardFrame(for: focusedTerminal) else {
            return
        }
        tabManager.keyboardCoordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            frame
        )
    }

    private func toggleServerMetadata() {
        guard let activeServer else { return }
        let servers = serverManager.stateStore.servers.isEmpty
            ? navigationFixtureServers(activeServer: activeServer)
            : []
        serverManager.stateStore.replaceCollections(
            servers: servers,
            workspaces: serverManager.stateStore.workspaces
        )
    }

    private var fixtureDiagnosticFallback: String {
        switch fixtureState {
        case .preparing:
            "setup=preparing"
        case .ready:
            "setup=ready pane=missing"
        case .failed(let error):
            "setup=failed error=\(error)"
        }
    }

    private func prepareFixture() async {
        guard case .preparing = fixtureState else { return }

        do {
            let username = try fixtureUsername()
            let privateKey = try fixturePrivateKey()
            let server = Server(
                id: Self.serverId,
                workspaceId: Self.workspaceId,
                environment: .development,
                name: "DEV-199 Loopback",
                host: Self.sshHost,
                port: Self.sshPort,
                username: username,
                connectionMode: .standard,
                authMethod: .sshKey,
                tmuxEnabledOverride: false
            )

            if !usesColdRelaunchHarness || seedsColdRelaunchHarness {
                await tabManager.resetForTesting()
            }
            KnownHostsManager.shared.remove(host: Self.sshHost, port: Self.sshPort)
            if !usesColdRelaunchHarness || seedsColdRelaunchHarness {
                try KeychainManager.shared.deleteCredentials(for: server.id)
            }
            var credentials = ServerCredentials(serverId: server.id)
            credentials.privateKey = privateKey
            try KeychainManager.shared.storeCredentials(credentials, for: server)
            if usesNavigationHarness {
                serverManager.stateStore.replaceCollections(
                    servers: navigationFixtureServers(activeServer: server),
                    workspaces: [
                        Workspace(
                            id: Self.workspaceId,
                            name: "DEV-213 Navigation"
                        )
                    ]
                )
            } else {
                serverManager.stateStore.replaceCollections(
                    servers: [server],
                    workspaces: serverManager.stateStore.workspaces
                )
            }

            if !usesColdRelaunchHarness || seedsColdRelaunchHarness {
                let firstTab = try await tabManager.openTab(for: server)
                if usesColdRelaunchHarness {
                    guard tabManager.splitHorizontal(
                        tab: firstTab,
                        paneId: firstTab.rootPaneId,
                        hasProAccess: true
                    ) != nil else {
                        throw VVTermError.connectionFailed("Unable to seed split layout")
                    }
                    let secondTab = try await tabManager.openTab(for: server)
                    tabManager.sessionState.selectTab(secondTab.id, for: server.id)
                } else {
                    tabManager.sessionState.selectTab(firstTab.id, for: server.id)
                }
            } else if tabManager.sessionState.tabs(for: server.id).isEmpty {
                throw VVTermError.connectionFailed("Cold relaunch snapshot was not restored")
            }
            tabManager.sessionState.selectView(.terminal, for: server.id)
            fixtureState = .ready(server)
        } catch {
            fixtureState = .failed(error.localizedDescription)
        }
    }

    private func fixtureUsername() throws -> String {
        guard let username = Self.fixtureDefaults.string(forKey: Self.fixtureUsernameDefaultsKey),
              !username.isEmpty else { throw FixtureError.missingUsername }
        return username
    }

    private func fixturePrivateKey() throws -> Data {
        guard let encoded = Self.fixtureDefaults.string(forKey: Self.fixturePrivateKeyDefaultsKey),
              let data = Data(base64Encoded: encoded),
              !data.isEmpty else {
            throw FixtureError.invalidPrivateKey
        }
        return data
    }

    private func navigationFixtureServers(activeServer: Server) -> [Server] {
        let fillerServers = (1...24).map { index in
            Server(
                workspaceId: Self.workspaceId,
                environment: .development,
                name: String(format: "Navigation Server %02d", index),
                host: "192.0.2.\(index)",
                username: "vvterm",
                authMethod: .password,
                tmuxEnabledOverride: false
            )
        }
        return fillerServers + [activeServer]
    }

}

private struct TerminalReconnectDiagnosticsLabel: UIViewRepresentable {
    let tabManager: TerminalTabManager
    let serverId: UUID?
    let fallback: String

    func makeCoordinator() -> Coordinator {
        Coordinator(tabManager: tabManager)
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = "vvterm.reconnectTest.diagnostics"
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        label.isUserInteractionEnabled = false
        label.numberOfLines = 12
        label.textColor = .white
        context.coordinator.install(label)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        context.coordinator.update(serverId: serverId, fallback: fallback)
    }

    static func dismantleUIView(_ label: UILabel, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator {
        private let tabManager: TerminalTabManager
        private weak var label: UILabel?
        private weak var configuredTerminal: GhosttyTerminalView?
        private var serverId: UUID?
        private var fallback = "setup=preparing"
        private var timer: Timer?

        init(tabManager: TerminalTabManager) {
            self.tabManager = tabManager
        }

        func install(_ label: UILabel) {
            self.label = label
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            refresh()
        }

        func update(serverId: UUID?, fallback: String) {
            self.serverId = serverId
            self.fallback = fallback
            refresh()
        }

        func invalidate() {
            timer?.invalidate()
            timer = nil
        }

        private func refresh() {
            guard let serverId,
                  let paneId = tabManager.sessionState.selectedTab(for: serverId)?.focusedPaneId else {
                publish(fallback)
                return
            }

            let state = tabManager.sessionState.paneState(for: paneId)?.connectionState ?? .idle
            let title = tabManager.titleStore.runtimeTitles[paneId] ?? "none"
            let workingDirectory = tabManager.sessionState.paneState(for: paneId)?.workingDirectory ?? "none"
            guard let terminal = tabManager.terminalSurfaceStore.ghosttySurface(for: paneId) else {
                publish("setup=ready state=\(connectionToken(state)) title=\(title) terminal=missing")
                return
            }

            if configuredTerminal !== terminal {
                terminal.keyboardUITestSetHardwareKeyboardAttached(false)
                if usesKeyboardFrameSimulation {
                    if let frame = terminalReconnectVisibleKeyboardFrame(for: terminal) {
                        tabManager.keyboardCoordinator.keyboardUITestSetSoftwareKeyboardEndFrame(frame)
                        configuredTerminal = terminal
                    }
                } else {
                    configuredTerminal = terminal
                }
            }
            terminal.isAccessibilityElement = true
            terminal.accessibilityIdentifier = "vvterm.reconnectTest.terminalSurface"
            let keyboard = tabManager.keyboardCoordinator
            let keyboardHeight = keyboard.softwareKeyboardEndFrame?.height ?? 0
            let shellId = tabManager.transportCoordinator.activeSSHRoute(for: paneId)?.shellId
            let terminalDiagnostics = terminal.keyboardUITestDiagnostics(
                keyboardVisible: keyboard.isSoftwareKeyboardVisible,
                keyboardHeight: keyboardHeight
            )
            publish([
                "setup=ready",
                "state=\(connectionToken(state))",
                "title=\(title)",
                "cwd=\(workingDirectory)",
                "shell=\(shellId != nil)",
                "shellId=\(shellId?.uuidString ?? "none")",
                terminalDiagnostics,
            ].joined(separator: " "))
        }

        private func publish(_ diagnostics: String) {
            label?.text = diagnostics
            label?.accessibilityLabel = diagnostics
        }

        private var usesKeyboardFrameSimulation: Bool {
            Foundation.ProcessInfo.processInfo.arguments.contains(
                "--vvterm-ui-test-simulate-keyboard-frames"
            )
        }

        private func connectionToken(_ state: ConnectionState) -> String {
            switch state {
            case .disconnected:
                "disconnected"
            case .connecting:
                "connecting"
            case .connected:
                "connected"
            case .reconnecting(let attempt):
                "reconnecting\(attempt)"
            case .failed:
                "failed"
            case .idle:
                "idle"
            }
        }
    }
}

private func terminalReconnectVisibleKeyboardFrame(for terminal: UIView) -> CGRect? {
    // Keyboard notifications use screen coordinates, while an iPad app window
    // can occupy only part of the display. Keep the simulated frame within the
    // terminal's actual window and convert it to the notification coordinate
    // space before forwarding it to the production coordinator.
    guard let window = terminal.window else { return nil }
    let bounds = window.screen.coordinateSpace.convert(window.bounds, from: window)
    let height = min(CGFloat(400), bounds.height)
    return CGRect(
        x: bounds.minX,
        y: bounds.maxY - height,
        width: bounds.width,
        height: height
    )
}
#endif
