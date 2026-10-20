#if DEBUG
import Foundation
import SwiftUI

@MainActor
struct ServerDuplicateUITestHarness: View {
    private actor AutomaticConnectionTester: ServerConnectionTesting {
        func test(
            server: Server,
            credentials: ServerCredentials
        ) async -> ServerConnectionTestResult {
            .successWithDetectedSystem(
                RemoteSystemIdentity(
                    kind: .macOS,
                    appleHardwareModelIdentifier: AppleHardwareModelIdentifier(
                        rawValue: "MacBookPro18,3"
                    )
                )
            )
        }
    }

    private static let fallbackWorkspaceID = UUID(
        uuidString: "9B678329-F5FC-4A81-971C-CFCAC3261656"
    )!

    @StateObject private var serverManager: ServerManager
    let dependencies: ServerFormDependencies
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory

    @State private var formIntent: ServerFormIntent?
    @State private var wakeActionCount = 0

    private static var usesTeleportFormHarness: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-server-form")
    }

    init(
        serverManager: ServerManager,
        dependencies: ServerFormDependencies,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory
    ) {
        if Self.usesTeleportFormHarness {
            let composition = TeleportServerFormUITestComposition(template: dependencies)
            _serverManager = StateObject(wrappedValue: composition.serverManager)
            self.dependencies = composition.formDependencies
        } else {
            _serverManager = StateObject(wrappedValue: serverManager)
            self.dependencies = dependencies
        }
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
    }

    private var workspace: Workspace? {
        serverManager.workspaces.first
    }

    private var sourceServer: Server {
        if Self.usesTeleportFormHarness,
           let saved = serverManager.servers.first {
            return saved
        }
        return Server(
            id: UUID(uuidString: "4BEE9E2E-E2CF-438C-A44C-B2391D0606E5")!,
            workspaceId: workspace?.id ?? Self.fallbackWorkspaceID,
            name: "DEV-397 UI Test Source",
            host: "duplicate-test.example.com",
            port: 2222,
            username: "wiedy",
            connectionMode: .tailscale,
            iconSelection: .custom(.database),
            detectedSystemIdentity: RemoteSystemIdentity(
                kind: .ubuntu,
                displayName: "Ubuntu 24.04 LTS"
            ),
            notes: "Duplicate form fixture"
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if Self.usesTeleportFormHarness {
                    Button("Add Server") { formIntent = .create(prefill: nil) }
                        .accessibilityIdentifier("vvterm.teleportFormTest.add")
                    TeleportDeviceCredentialUITestControls()
                }
                if !Self.usesTeleportFormHarness || !serverManager.servers.isEmpty {
                    #if os(iOS)
                    ServerListRow(
                        serverManager: serverManager,
                        server: sourceServer,
                        onTap: {},
                        onEdit: { formIntent = .edit(sourceServer) },
                        onMove: {},
                        onDuplicate: { formIntent = .duplicate(sourceServer) },
                        onWake: { wakeActionCount += 1 }
                    )
                    .accessibilityIdentifier("vvterm.serverDuplicateTest.row")

                    Text("\(wakeActionCount)")
                        .accessibilityIdentifier("vvterm.serverWakeTest.actionCount")
                    #else
                    Button {
                        formIntent = .duplicate(sourceServer)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .accessibilityIdentifier("vvterm.serverDuplicateTest.action")
                    #endif
                }
            }
            .navigationTitle("Server Duplicate Test")
        }
        .sheet(item: $formIntent) { intent in
            formSheet(for: intent)
        }
        .accessibilityIdentifier("vvterm.serverDuplicateTest.root")
    }

    @ViewBuilder
    private func formSheet(for intent: ServerFormIntent) -> some View {
        #if os(iOS)
        NavigationStack {
            serverForm(for: intent)
        }
        #else
        serverForm(for: intent)
            .frame(
                minWidth: 640,
                idealWidth: 700,
                maxWidth: 760,
                minHeight: 520,
                idealHeight: 620,
                maxHeight: 680
            )
        #endif
    }

    private func serverForm(for intent: ServerFormIntent) -> some View {
        ServerFormSheet(
            serverManager: serverManager,
            workspace: workspace,
            intent: intent,
            dependencies: automaticDetectionDependencies,
            makeLocalDiscoveryManager: makeLocalDiscoveryManager,
            onSave: { _ in formIntent = nil }
        )
    }

    private var automaticDetectionDependencies: ServerFormDependencies {
        ServerFormDependencies(
            credentials: dependencies.credentials,
            connectionTester: AutomaticConnectionTester(),
            wakeOnLANMACAddressResolver: dependencies.wakeOnLANMACAddressResolver,
            hostKeys: dependencies.hostKeys,
            remoteSessionBackends: dependencies.remoteSessionBackends,
            defaultRemoteSessionEnabled: dependencies.defaultRemoteSessionEnabled,
            defaultRemoteSessionBackendIdentifier:
                dependencies.defaultRemoteSessionBackendIdentifier,
            defaultRemoteSessionStartupBehavior:
                dependencies.defaultRemoteSessionStartupBehavior,
            now: dependencies.now,
            makeID: dependencies.makeID
        )
    }
}
#endif
