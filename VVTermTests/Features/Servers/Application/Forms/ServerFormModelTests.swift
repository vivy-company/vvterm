import Foundation
import Testing
@testable import VVTerm

struct ServerFormModelTests {
    @Test
    func unsupportedTransportCannotBeSavedAsSSH() {
        let server = Server(
            workspaceId: UUID(), name: "Future connection", host: "example.test", username: "test",
            connectionMode: .unsupported("future-transport")
        )
        let model = ServerFormModel(
            server: server, defaultRemoteSessionEnabled: false,
            defaultRemoteSessionBackendIdentifier: .tmux, defaultRemoteSessionStartupBehavior: .ask
        )
        #expect(model.transportSelection == .unsupported)
        #expect(!model.isValid)
        #expect(!ServerTransportSelection.allCases.contains(.unsupported))
    }

    @Test
    func teleportDraftSavesBeforeLoginWithoutOrdinaryCredentialsOrDirectPorts() throws {
        var model = validTeleportModel()
        model.host = ""
        model.port = "not-a-TCP-port"
        model.password = "unused-test-input"
        model.autoWakeOnLANEnabled = true
        #expect(model.isValid)
        let serverID = UUID()
        let server = model.makeServer(id: serverID, workspaceID: UUID(), createdAt: .distantPast)
        let credentials = model.makeCredentials(serverID: serverID)
        #expect(server.connectionMode == .teleport)
        #expect(server.authMethod == nil)
        #expect(server.teleportConfiguration?.nodeID == "node-id")
        #expect(server.teleportConfiguration?.profile.account == "alice")
        #expect(!server.autoWakeOnLANEnabled)
        #expect(model.wakeOnLANSavePlan(existingServer: nil) == .clearConfiguration)
        #expect(credentials.password == nil)
        #expect(credentials.privateKey == nil)
        #expect(credentials.passphrase == nil)
        #expect(credentials.cloudflareClientID == nil)
        model.username = " "
        #expect(!model.isValid)
        model.username = "deploy"
        model.teleportClusterName = ""
        #expect(!model.isValid)
    }

    @Test
    func teleportProfileChangesInvalidateConnectionResultsAndSystemDetection() {
        var model = validTeleportModel()
        model.applyDetectedSystemIdentity(RemoteSystemIdentity(kind: .ubuntu))
        let snapshot = model.connectionSnapshot
        #expect(model.currentDetectedSystemIdentity != nil)
        model.teleportAccount = "bob"
        #expect(model.connectionSnapshot != snapshot)
        #expect(model.currentDetectedSystemIdentity == nil)
    }

    private func validTeleportModel() -> ServerFormModel {
        var model = ServerFormModel(
            defaultRemoteSessionEnabled: false,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .ask
        )
        model.name = "Teleport node"
        model.transportSelection = .teleport
        model.teleportProxyURL = "https://proxy.example.test"
        model.teleportAccount = "alice"
        model.teleportClusterName = "root.example.test"
        model.teleportNodeID = "node-id"
        model.username = "deploy"
        return model
    }

    @Test
    func modelBuildsServerAndCredentialsFromOneDraft() throws {
        let workspaceID = UUID()
        let serverID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var model = ServerFormModel(
            workspaceID: workspaceID,
            defaultRemoteSessionEnabled: false,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .ask
        )
        model.name = "Production"
        model.host = "host.example.com"
        model.port = "2222"
        model.eternalTerminalPort = "22022"
        model.username = "  "
        model.transportSelection = .cloudflare
        model.authMethod = .sshKeyWithPassphrase
        model.sshKey = "PRIVATE"
        model.sshPassphrase = "phrase"
        model.sshPublicKey = "PUBLIC"
        model.cloudflareAccessMode = .serviceToken
        model.cloudflareClientID = " client-id "
        model.cloudflareClientSecret = " client-secret "
        model.cloudflareTeamDomainOverride = " team.cloudflareaccess.com "
        model.notes = "notes"
        model.requiresBiometricUnlock = true
        model.remoteSessionEnabled = true
        model.remoteSessionBackendIdentifier = .zmx
        model.remoteSessionStartupBehavior = .createManaged
        model.remoteShellStartupAction.command = "cd /srv/app && exec $SHELL -l"

        #expect(model.isValid)

        let server = model.makeServer(
            id: serverID,
            workspaceID: workspaceID,
            createdAt: createdAt
        )
        let credentials = model.makeCredentials(serverID: serverID)

        #expect(server.id == serverID)
        #expect(server.workspaceId == workspaceID)
        #expect(server.port == 2222)
        #expect(server.eternalTerminalPort == 22022)
        #expect(server.username == "root")
        #expect(server.connectionMode == .cloudflare)
        #expect(server.cloudflareAccessMode == .serviceToken)
        #expect(server.cloudflareTeamDomainOverride == "team.cloudflareaccess.com")
        #expect(server.remoteSessionEnabledOverride == true)
        #expect(server.remoteSessionBackendIdentifier == .zmx)
        #expect(server.remoteSessionStartupBehaviorOverride == .createManaged)
        #expect(server.remoteShellStartupAction?.command == "cd /srv/app && exec $SHELL -l")
        #expect(server.createdAt == createdAt)
        #expect(String(data: try #require(credentials.privateKey), encoding: .utf8) == "PRIVATE")
        #expect(credentials.passphrase == "phrase")
        #expect(String(data: try #require(credentials.publicKey), encoding: .utf8) == "PUBLIC")
        #expect(credentials.cloudflareClientID == "client-id")
        #expect(credentials.cloudflareClientSecret == "client-secret")
    }

    @Test
    func validationRejectsOutOfRangePortsAndIncompleteCredentials() {
        var model = validPasswordModel()

        model.port = "0"
        #expect(!model.isValid)
        model.port = "65536"
        #expect(!model.isValid)
        model.port = "65535"
        #expect(model.isValid)

        model.transportSelection = .eternalTerminal
        model.eternalTerminalPort = "65536"
        #expect(!model.isValid)

        model.transportSelection = .cloudflare
        model.cloudflareAccessMode = .serviceToken
        model.eternalTerminalPort = "2022"
        model.cloudflareClientID = " "
        model.cloudflareClientSecret = "secret"
        #expect(!model.isValid)
    }

    @Test
    func connectionSnapshotChangesOnlyWithConnectionFacts() {
        var model = validPasswordModel()
        let snapshot = model.connectionSnapshot

        model.name = "Renamed"
        model.notes = "New note"
        model.workspaceID = UUID()
        #expect(model.connectionSnapshot == snapshot)

        model.host = "other.example.com"
        #expect(model.connectionSnapshot != snapshot)
    }

    @Test
    func wakeOnLANPlanPreservesOnlyTheConfigurationForTheSameHost() throws {
        let configuration = WakeOnLANConfiguration(
            macAddress: try WakeOnLANMACAddress("AA:BB:CC:DD:EE:FF")
        )
        let server = Server(
            workspaceId: UUID(),
            name: "Local",
            host: " 192.168.1.10 ",
            username: "root",
            wakeOnLANConfiguration: configuration
        )
        var model = ServerFormModel(
            server: server,
            defaultRemoteSessionEnabled: true,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .createManaged
        )

        #expect(model.wakeOnLANSavePlan(existingServer: server) == .configured(configuration))

        model.host = "192.168.1.11"
        #expect(model.wakeOnLANSavePlan(existingServer: server) == .clearConfiguration)

        model.autoWakeOnLANEnabled = true
        #expect(model.wakeOnLANSavePlan(existingServer: server) == .resolveAutomatically)

        model.autoWakeOnLANEnabled = false
        #expect(model.wakeOnLANSavePlan(existingServer: server) == .clearConfiguration)
    }

    @Test
    func enablingAutomaticWakeWithoutAStoredAddressRequiresAutomaticResolution() {
        var model = validPasswordModel()
        model.autoWakeOnLANEnabled = true

        #expect(model.wakeOnLANSavePlan(existingServer: nil) == .resolveAutomatically)
    }

    @Test
    func editModelRestoresServerIdentityAndCredentialValues() throws {
        let server = Server(
            id: UUID(),
            workspaceId: UUID(),
            environment: .staging,
            name: "Edit",
            host: "edit.example.com",
            port: 2200,
            username: "deploy",
            connectionMode: .standard,
            authMethod: .sshKeyWithPassphrase,
            notes: "keep",
            requiresBiometricUnlock: true,
            remoteSessionEnabledOverride: false,
            remoteSessionBackendIdentifier: .zmx,
            remoteSessionStartupBehaviorOverride: .ask,
            remoteShellStartupCommand: "cd /srv/edit && exec $SHELL -l"
        )
        var model = ServerFormModel(
            server: server,
            defaultRemoteSessionEnabled: true,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .createManaged
        )
        var credentials = ServerCredentials(serverId: server.id)
        credentials.privateKey = Data("PRIVATE".utf8)
        credentials.publicKey = Data("PUBLIC".utf8)
        credentials.passphrase = "phrase"
        model.apply(credentials, for: server)

        let rebuilt = model.makeServer(
            id: server.id,
            workspaceID: try #require(model.workspaceID),
            createdAt: server.createdAt
        )

        #expect(rebuilt.id == server.id)
        #expect(rebuilt.workspaceId == server.workspaceId)
        #expect(rebuilt.environment == server.environment)
        #expect(rebuilt.name == server.name)
        #expect(rebuilt.host == server.host)
        #expect(rebuilt.username == server.username)
        #expect(rebuilt.notes == server.notes)
        #expect(rebuilt.remoteSessionEnabledOverride == false)
        #expect(rebuilt.remoteSessionBackendIdentifier == .zmx)
        #expect(rebuilt.remoteSessionStartupBehaviorOverride == .ask)
        #expect(rebuilt.remoteShellStartupAction?.command == "cd /srv/edit && exec $SHELL -l")
        #expect(model.sshKey == "PRIVATE")
        #expect(model.sshPublicKey == "PUBLIC")
        #expect(model.sshPassphrase == "phrase")
    }

    @Test
    func endpointChangeClearsDetectionButKeepsManualIcon() throws {
        let identity = RemoteSystemIdentity(kind: .ubuntu, displayName: "Ubuntu 24.04")
        let server = Server(
            workspaceId: UUID(),
            name: "Server",
            host: "old.example.com",
            port: 22,
            username: "root",
            iconSelection: .custom(.database),
            detectedSystemIdentity: identity
        )
        var model = ServerFormModel(
            server: server,
            defaultRemoteSessionEnabled: true,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .createManaged
        )
        model.host = "new.example.com"

        #expect(model.currentDetectedSystemIdentity == nil)

        let rebuilt = model.makeServer(
            id: server.id,
            workspaceID: server.workspaceId,
            createdAt: server.createdAt
        )

        #expect(rebuilt.iconSelection == .custom(.database))
        #expect(rebuilt.detectedSystemIdentity == nil)
    }

    @Test
    func freshDetectionForChangedEndpointIsPersisted() {
        let oldIdentity = RemoteSystemIdentity(kind: .ubuntu)
        let newIdentity = RemoteSystemIdentity(kind: .windows, displayName: "Windows 11")
        let server = Server(
            workspaceId: UUID(),
            name: "Server",
            host: "old.example.com",
            username: "root",
            detectedSystemIdentity: oldIdentity
        )
        var model = ServerFormModel(
            server: server,
            defaultRemoteSessionEnabled: true,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .createManaged
        )
        model.host = "new.example.com"
        model.applyDetectedSystemIdentity(newIdentity)

        #expect(model.currentDetectedSystemIdentity == newIdentity)

        let rebuilt = model.makeServer(
            id: server.id,
            workspaceID: server.workspaceId,
            createdAt: server.createdAt
        )

        #expect(rebuilt.detectedSystemIdentity == newIdentity)
    }

    @Test
    func equivalentEndpointFormattingKeepsDetection() {
        let identity = RemoteSystemIdentity(kind: .debian)
        let server = Server(
            workspaceId: UUID(),
            name: "Server",
            host: "Example.COM",
            port: 22,
            username: "root",
            detectedSystemIdentity: identity
        )
        var model = ServerFormModel(
            server: server,
            defaultRemoteSessionEnabled: true,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .createManaged
        )
        model.host = " example.com "
        model.port = "022"

        #expect(model.currentDetectedSystemIdentity == identity)

        let rebuilt = model.makeServer(
            id: server.id,
            workspaceID: server.workspaceId,
            createdAt: server.createdAt
        )

        #expect(rebuilt.detectedSystemIdentity == identity)
    }

    private func validPasswordModel() -> ServerFormModel {
        var model = ServerFormModel(
            defaultRemoteSessionEnabled: true,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .createManaged
        )
        model.name = "Server"
        model.host = "example.com"
        model.port = "22"
        model.password = "secret"
        return model
    }
}
