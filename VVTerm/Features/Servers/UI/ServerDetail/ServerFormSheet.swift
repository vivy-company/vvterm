import SwiftUI
import TeleportKit

extension ServerTransportSelection {
    var displayName: String {
        switch self {
        case .standard:
            return String(localized: "SSH")
        case .tailscale:
            return String(localized: "Tailscale")
        case .mosh:
            return String(localized: "Mosh")
        case .eternalTerminal:
            return String(localized: "Eternal Terminal")
        case .cloudflare:
            return String(localized: "Cloudflare")
        case .teleport:
            return String(localized: "Teleport")
        case .unsupported:
            return String(localized: "Unsupported connection type")
        }
    }

    var icon: String {
        switch self {
        case .standard:
            return "terminal"
        case .tailscale:
            return "network"
        case .mosh:
            return "antenna.radiowaves.left.and.right"
        case .eternalTerminal:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .cloudflare:
            return "shield.lefthalf.filled"
        case .teleport:
            return "arrow.up.forward.circle"
        case .unsupported:
            return "questionmark.circle"
        }
    }

}

// MARK: - Server Form Sheet

struct ServerFormSheet: View {
    let serverManager: ServerManager
    @ObservedObject private var stateStore: ServerStateStore
    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var appLockManager: AppLockManager
    let workspace: Workspace?
    let intent: ServerFormIntent
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    let onSave: (Server) -> Void

    @Environment(\.dismiss) var dismiss

    @State private var form: ServerFormModel
    @StateObject private var operations: ServerFormOperationController
    // Keep authentication alive when its form sections move off screen.
    @State private var teleportModel: TeleportProfileModel?
    @State private var showCloudflareOverrides: Bool = false

    @State private var showingServerLimitAlert = false
    @State private var showingCreateWorkspace = false
    @State private var showingAddKeySheet = false
    @State private var programmaticSSHKeyValue: String?
    @State private var localDiscoveryPresentation: LocalDeviceDiscoveryPresentation?
    @State private var hasAuthorizedSourceAccess: Bool

    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let remoteSessionBackends: [RemoteSessionBackendMetadata]
    private let teleportAccess: TeleportAccessService?

    var isEditing: Bool { intent.isEditing }

    private var sourceServer: Server? { intent.sourceServer }

    private var activeTeleportProfile: TeleportProfileConfiguration? {
        form.transportSelection == .teleport ? form.teleportProfile : nil
    }

    private var hostKeyTrustRequest: ServerSecurityApprovalRequest? {
        operations.hostKeyChallenge.map(ServerSecurityApprovalRequest.hostKey)
    }

    init(
        serverManager: ServerManager,
        workspace: Workspace?,
        intent: ServerFormIntent,
        dependencies: ServerFormDependencies,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        onSave: @escaping (Server) -> Void
    ) {
        self.serverManager = serverManager
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
        self.workspace = workspace
        self.intent = intent
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.now = dependencies.now
        self.makeID = dependencies.makeID
        remoteSessionBackends = dependencies.remoteSessionBackends
        teleportAccess = dependencies.teleportAccess
        let saveUseCase = ServerSaveUseCase(mutations: serverManager)
        self.onSave = onSave
        _operations = StateObject(
            wrappedValue: ServerFormOperationController(
                credentialLoader: ServerFormCredentialLoader(
                    repository: dependencies.credentials
                ),
                connectionTester: dependencies.connectionTester,
                wakeOnLANMACAddressResolver: dependencies.wakeOnLANMACAddressResolver,
                hostKeys: dependencies.hostKeys,
                saveUseCase: saveUseCase,
                now: dependencies.now,
                makeID: dependencies.makeID
            )
        )

        var initialForm = ServerFormModel(
            server: intent.sourceServer,
            workspaceID: workspace?.id,
            defaultRemoteSessionEnabled: dependencies.defaultRemoteSessionEnabled(),
            defaultRemoteSessionBackendIdentifier:
                dependencies.defaultRemoteSessionBackendIdentifier(),
            defaultRemoteSessionStartupBehavior: dependencies.defaultRemoteSessionStartupBehavior()
        )
        if let prefill = intent.prefill {
            initialForm.applyPrefill(
                name: prefill.name,
                host: prefill.host,
                port: prefill.port,
                username: prefill.username
            )
        }
        if case .duplicate(let source) = intent {
            let baseName = String(
                format: String(localized: "%@ Copy"),
                source.name
            )
            initialForm.name = ServerDuplicateNamePolicy.uniqueName(
                baseName: baseName,
                existingNames: serverManager.servers.map(\.name)
            )
        }
        if !intent.isEditing {
            initialForm.autoWakeOnLANEnabled = false
        }
        _form = State(initialValue: initialForm)
        _hasAuthorizedSourceAccess = State(
            initialValue: intent.sourceServer?.requiresBiometricUnlock != true
        )
        _showCloudflareOverrides = State(
            initialValue: !(intent.sourceServer?.cloudflareTeamDomainOverride ?? "").isEmpty
        )
    }

    private var serverCount: Int {
        stateStore.servers.count
    }

    private var isAtLimit: Bool {
        !isEditing && !stateStore.canAddServer(hasProAccess: storeManager.allowsProFeatures)
    }

    private var assignmentWorkspaces: [Workspace] {
        stateStore.assignmentWorkspaces(
            for: sourceServer,
            hasProAccess: storeManager.allowsProFeatures
        )
    }

    private var selectedWorkspace: Workspace? {
        if let workspaceID = form.workspaceID,
           let matchingWorkspace = assignmentWorkspaces.first(where: { $0.id == workspaceID }) {
            return matchingWorkspace
        }

        return assignmentWorkspaces.first
    }

    private var workspaceEnvironmentNotice: String? {
        guard let sourceServer,
              let selectedWorkspace,
              selectedWorkspace.id != sourceServer.workspaceId,
              stateStore.moveRequiresEnvironmentFallback(
                sourceServer,
                destination: selectedWorkspace
              ) else {
            return nil
        }

        let resolvedEnvironment = stateStore.resolvedEnvironment(
            for: sourceServer,
            destination: selectedWorkspace,
            preferredEnvironment: form.environment
        )

        return String(
            format: String(localized: "\"%@\" isn't available in %@. The server will use %@ there."),
            sourceServer.environment.displayName,
            selectedWorkspace.name,
            resolvedEnvironment.displayName
        )
    }

    private var workspaceAvailabilityHelpText: String? {
        guard assignmentWorkspaces.count <= 1 else {
            return nil
        }

        if stateStore.workspaces.count <= 1 {
            if isEditing {
                return String(localized: "No additional workspaces yet. Create one to move this server.")
            }

            return String(localized: "No additional workspaces yet. Create one to organize servers separately.")
        }

        return String(localized: "No additional workspace is available for this server right now.")
    }

    private var automaticConnectionTestSnapshot: ServerFormModel.ConnectionSnapshot? {
        let snapshot = form.connectionSnapshot
        guard hasAuthorizedSourceAccess,
              form.transportSelection != .teleport,
              form.iconSelection == .automatic,
              form.isValid,
              !isLoadingCredentials,
              !isTestingConnection,
              !isSaving,
              operations.failure == nil,
              !operations.requiresUpgrade,
              !operations.hasCompletedConnectionTest(for: snapshot) else {
            return nil
        }
        return snapshot
    }

    private var hasCustomStartupCommand: Bool {
        !form.remoteShellStartupAction.command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var selectedRemoteSessionBackend: RemoteSessionBackendMetadata? {
        remoteSessionBackends.first {
            $0.identifier == form.remoteSessionBackendIdentifier
        }
    }

    private var unsupportedManagedStartupBackend: RemoteSessionBackendMetadata? {
        guard form.remoteSessionEnabled,
              hasCustomStartupCommand,
              let backend = selectedRemoteSessionBackend,
              backend.managedStartupCommandSupport == .unsupported else {
            return nil
        }
        return backend
    }

    var isSaving: Bool { operations.isSaving }

    private var isLoadingCredentials: Bool { operations.isLoadingCredentials }

    private var isTestingConnection: Bool { operations.isTestingConnection }

    var saveButtonDisabled: Bool {
        !form.isValid || isSaving || isAtLimit
            || isLoadingCredentials || isTestingConnection
            || unsupportedManagedStartupBackend != nil
    }

    private var serverLimitAlertBinding: Binding<Bool> {
        Binding(
            get: { showingServerLimitAlert || operations.requiresUpgrade },
            set: { isPresented in
                showingServerLimitAlert = isPresented
                if !isPresented { operations.clearPresentation() }
            }
        )
    }

    private var hostKeyTrustBinding: Binding<Bool> {
        Binding(
            get: { operations.hostKeyChallenge != nil },
            set: { if !$0 { operations.rejectHostKeyChallenge() } }
        )
    }

    var body: some View {
        ZStack {
            platformBody
                .opacity(hasAuthorizedSourceAccess ? 1 : 0)
                .allowsHitTesting(hasAuthorizedSourceAccess)
                .accessibilityHidden(!hasAuthorizedSourceAccess)

            if !hasAuthorizedSourceAccess {
                ProgressView("Authorizing…")
                    .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var connectionFormSections: some View {
        limitSection
        serverSection
        authSection
        if let profile = activeTeleportProfile,
           let teleportModel, teleportModel.profile == profile,
           let teleportAccess {
            TeleportProfileSection(
                model: teleportModel, service: teleportAccess,
                clusterName: $form.teleportClusterName,
                nodeID: $form.teleportNodeID, login: $form.username
            ) { nodeName in
                if form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    form.name = nodeName
                }
            }
        }
        iconSection
        sessionSection
        RemoteShellStartupActionSection(
            model: $form.remoteShellStartupAction,
            remoteSessionEnabled: form.remoteSessionEnabled
        )
    }

    @ViewBuilder
    private var detailFormSections: some View {
        securitySection
        assignmentSection
        notesSection
        if isEditing && form.transportSelection != .teleport {
            advancedSection
        }
        errorSection
    }

    private var styledFormContent: some View {
        Form {
            connectionFormSections
            detailFormSections
        }
        .formStyle(.grouped)
        .serverFormPlatformStyle(
            title: isEditing ? String(localized: "Edit Server") : String(localized: "Add Server")
        )
    }

    private var presentedFormContent: some View {
        styledFormContent
        .interactiveDismissDisabled(isSaving)
        .task {
            if let sourceServer {
                guard await appLockManager.authorizeProtectedServerAction(
                    sourceServer,
                    action: .edit
                ) else {
                    dismiss()
                    return
                }
                hasAuthorizedSourceAccess = true
            }
            operations.loadFormCredentials(for: sourceServer) { credentials in
                if let privateKey = credentials.privateKey,
                   let key = String(data: privateKey, encoding: .utf8) {
                    programmaticSSHKeyValue = key
                }
                guard let sourceServer else { return }
                form.apply(credentials, for: sourceServer)
            }
        }
            .serverFormPlatformActions(
                isEditing: isEditing,
                isSaving: isSaving,
                saveButtonDisabled: saveButtonDisabled,
                onCancel: { dismiss() },
                onSave: saveServer
            )
            .adaptiveSoftScrollEdges()
            .sheet(isPresented: $showingAddKeySheet) {
                AddSSHKeySheet(onSave: { entry in
                    operations.refreshStoredKeys(selecting: entry.id) { loadedKey in
                        applyStoredKey(loadedKey)
                    }
                })
                .adaptiveSoftScrollEdges()
            }
            .sheet(isPresented: $showingCreateWorkspace) {
                WorkspaceFormSheet(
                    serverManager: serverManager,
                    onSave: { workspace in
                        form.workspaceID = workspace.id
                    }
                )
                .adaptiveSoftScrollEdges()
            }
            .sheet(item: $localDiscoveryPresentation) { presentation in
                LocalDeviceDiscoverySheet(manager: presentation.manager) { discoveredHost in
                    applyPrefill(
                        ServerFormPrefill(
                            name: discoveredHost.displayName,
                            host: discoveredHost.host,
                            port: discoveredHost.port
                        )
                    )
                }
                .adaptiveSoftScrollEdges()
            }
            .limitReachedAlert(.servers, isPresented: serverLimitAlertBinding)
            .sshHostKeyTrustAlert(
                request: hostKeyTrustRequest,
                isPresented: hostKeyTrustBinding,
                onCancel: { _ in rejectHostKeyChallenge() },
                onApprove: { _ in approveHostKeyChallengeAndRetest() }
            )
    }

    private var lifecycleFormContent: some View {
        presentedFormContent
            .task(id: automaticConnectionTestSnapshot) {
                guard let snapshot = automaticConnectionTestSnapshot else { return }
                do {
                    try await Task.sleep(nanoseconds: 700_000_000)
                } catch {
                    return
                }
                guard snapshot == form.connectionSnapshot else { return }
                await runConnectionTest(force: false)
            }
            .onAppear {
                reconcileAssignmentWorkspace()
                updateTeleportProfile()
                teleportModel?.load()
            }
            .onChange(of: activeTeleportProfile) { _ in
                // A password for another origin or account must never reach this profile.
                form.password = ""
                operations.invalidateCredentialLoading()
                updateTeleportProfile()
            }
            .onChange(of: operations.connectionTestFailure) { failure in
                if failure?.requiresCloudflareOverrides == true {
                    showCloudflareOverrides = true
                }
            }
            .onDisappear {
                operations.cancel()
                teleportModel?.cancel()
            }
            .onChange(of: form.host) { _ in resetConnectionTestState() }
            .onChange(of: form.port) { _ in resetConnectionTestState() }
            .onChange(of: form.eternalTerminalPort) { _ in resetConnectionTestState() }
            .onChange(of: form.username) { _ in resetConnectionTestState() }
            .onChange(of: form.transportSelection) { _ in handleCredentialIntentChange() }
            .onChange(of: form.teleportConfiguration) { _ in resetConnectionTestState() }
            .onChange(of: form.authMethod) { _ in handleCredentialIntentChange() }
    }

    var formContent: some View {
        lifecycleFormContent
            .onChange(of: form.workspaceID) { _ in
                reconcileAssignmentWorkspace()
                resetConnectionTestState()
            }
            .onChange(of: form.password) { _ in handleCredentialIntentChange() }
            .onChange(of: form.sshKey) { _ in
                if let programmaticSSHKeyValue,
                   form.sshKey == programmaticSSHKeyValue {
                    self.programmaticSSHKeyValue = nil
                } else {
                    operations.clearStoredKeySelection()
                    form.sshPublicKey = ""
                }
                resetConnectionTestState()
            }
            .onChange(of: form.sshPassphrase) { _ in handleCredentialIntentChange() }
            .onChange(of: form.sshPublicKey) { _ in handleCredentialIntentChange() }
            .onChange(of: form.cloudflareAccessMode) { _ in handleCredentialIntentChange() }
            .onChange(of: form.cloudflareClientID) { _ in handleCredentialIntentChange() }
            .onChange(of: form.cloudflareClientSecret) { _ in handleCredentialIntentChange() }
            .onChange(of: form.cloudflareTeamDomainOverride) { _ in handleCredentialIntentChange() }
    }

    @ViewBuilder
    private var assignmentSection: some View {
        Section {
            if assignmentWorkspaces.count > 1 {
                Picker("Workspace", selection: $form.workspaceID) {
                    ForEach(assignmentWorkspaces) { workspace in
                        HStack(spacing: 8) {
                            if stateStore.isWorkspaceLocked(workspace, hasProAccess: storeManager.allowsProFeatures) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                Circle()
                                    .fill(Color.fromHex(workspace.colorHex))
                                    .frame(width: 8, height: 8)
                            }

                            Text(workspace.name)
                        }
                        .tag(Optional(workspace.id))
                    }
                }
            } else {
                LabeledContent("Workspace") {
                    if let selectedWorkspace {
                        HStack(spacing: 8) {
                            if stateStore.isWorkspaceLocked(selectedWorkspace, hasProAccess: storeManager.allowsProFeatures) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                Circle()
                                    .fill(Color.fromHex(selectedWorkspace.colorHex))
                                    .frame(width: 8, height: 8)
                            }

                            Text(selectedWorkspace.name)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No Workspace")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Environment", selection: $form.environment) {
                ForEach(selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments) { env in
                    HStack {
                        Circle()
                            .fill(env.color)
                            .frame(width: 8, height: 8)
                        Text(env.displayName)
                    }
                    .tag(env)
                }
            }

            if let workspaceEnvironmentNotice {
                Text(workspaceEnvironmentNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if assignmentWorkspaces.count <= 1 {
                Button {
                    showingCreateWorkspace = true
                } label: {
                    Label("Create Workspace", systemImage: "folder.badge.plus")
                }
            }
        } header: {
            sectionHeader("Workspace")
        } footer: {
            if let workspaceAvailabilityHelpText {
                Text(workspaceAvailabilityHelpText)
            }
        }
    }

    @ViewBuilder
    private var limitSection: some View {
        if isAtLimit {
            Section {
                ProLimitBanner(
                    title: String(localized: "Server Limit Reached"),
                    message: String(
                        format: String(localized: "You've reached the free limit of %@. Pro unlocks unlimited servers, connections, and split panes."),
                        FreeTierLimitPresentation.serverCountDescription(stateStore.freeServerLimit)
                    )
                ) {
                    showingServerLimitAlert = true
                }
            }
        } else if !isEditing && !storeManager.allowsProFeatures {
            Section {
                UsageIndicator(
                    current: serverCount,
                    limit: stateStore.freeServerLimit,
                    label: String(localized: "Servers"),
                    showUpgrade: $showingServerLimitAlert
                )
            }
        }
    }

    private var serverSection: some View {
        Section {
            TextField("Name", text: $form.name, prompt: Text(String(localized: "My Server")))
                .accessibilityIdentifier("vvterm.serverForm.name")
                #if os(iOS)
                .textContentType(.name)
                #endif

            if form.transportSelection != .teleport {
                HStack(spacing: 12) {
                    TextField("Host", text: $form.host, prompt: Text(String(localized: "203.0.113.10")))
                        .accessibilityIdentifier("vvterm.serverForm.host")
                        #if os(iOS)
                        .textContentType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif

                    TextField("Port", text: $form.port, prompt: Text(String(localized: "22")))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .frame(width: 76)
                }

                TextField("Username", text: $form.username, prompt: Text(String(localized: "root")))
                    .accessibilityIdentifier("vvterm.serverForm.username")
                    #if os(iOS)
                    .textContentType(.username)
                    #endif
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Button {
                    presentLocalDiscovery()
                } label: {
                    Label(String(localized: "Pick from Local Discovery..."), systemImage: "dot.radiowaves.left.and.right")
                }
            }
        } header: {
            sectionHeader("Server")
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section {
            Picker("Transport", selection: Binding(
                get: { form.transportSelection },
                set: { form.selectTransport($0) }
            )) {
                if form.transportSelection == .unsupported {
                    Text("Unsupported connection type").tag(ServerTransportSelection.unsupported)
                }
                ForEach(ServerTransportSelection.allCases) { transport in
                    Label(transport.displayName, systemImage: transport.icon)
                        .tag(transport)
                }
            }
            .accessibilityIdentifier("vvterm.serverForm.transport")

            if form.transportSelection == .teleport {
                TextField("Teleport address", text: $form.teleportProxyURL, prompt: Text("teleport.example.com"))
                    .accessibilityIdentifier("vvterm.serverForm.teleport.proxy")
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Username", text: $form.teleportAccount, prompt: Text("Teleport username"))
                    .accessibilityIdentifier("vvterm.serverForm.teleport.account")
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Text("Sign in, then choose a node and OS login. Profile settings sync between devices. Issued access stays on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if form.transportSelection == .eternalTerminal {
                TextField("ET Port", text: $form.eternalTerminalPort, prompt: Text("2022"))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif

                Text(String(localized: "Eternal Terminal uses SSH to start etterminal, then connects directly to etserver. Install Eternal Terminal on the host and allow inbound TCP traffic to the ET port."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if form.transportSelection == .cloudflare {
                Picker("Cloudflare Access", selection: $form.cloudflareAccessMode) {
                    ForEach(CloudflareAccessMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                switch form.cloudflareAccessMode {
                case .oauth:
                    Text(String(localized: "OAuth login will open in browser. Team/App domain values are auto-discovered from host."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showCloudflareOverrides {
                        TextField("Team Domain Override", text: $form.cloudflareTeamDomainOverride, prompt: Text("team.cloudflareaccess.com"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        Button("Hide Overrides") {
                            showCloudflareOverrides = false
                        }
                    } else {
                        Button("Set Team Domain Override") {
                            showCloudflareOverrides = true
                        }
                    }

                case .serviceToken:
                    TextField("Service Token Client ID", text: $form.cloudflareClientID, prompt: Text(String(localized: "Required")))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Service Token Client Secret", text: $form.cloudflareClientSecret, prompt: Text(String(localized: "Required")))
                }
            }

            if form.transportSelection != .tailscale && form.transportSelection != .teleport {
                Picker("Method", selection: $form.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Label(method.displayName, systemImage: method.icon)
                            .tag(method)
                    }
                }
                .accessibilityIdentifier("vvterm.serverForm.authMethod")

                switch form.authMethod {
                case .password:
                    SecureField("Password", text: $form.password, prompt: Text(String(localized: "Required")))
                        #if os(iOS)
                        .textContentType(.password)
                        #endif

                case .sshKey:
                    keyInputView

                case .sshKeyWithPassphrase:
                    keyInputView
                    SecureField("Key Passphrase", text: $form.sshPassphrase, prompt: Text(String(localized: "Optional")))
                }
            } else if form.transportSelection == .tailscale {
                Text(String(localized: "Uses server-side Tailscale SSH policy. No password or SSH key is required."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Authentication")
        }
    }

    private var iconSection: some View {
        Section {
            ServerIconPicker(
                selection: $form.iconSelection,
                detectedSystemIdentity: form.currentDetectedSystemIdentity,
                isDetecting: isTestingConnection
            )
        } header: {
            sectionHeader("Icon")
        }
    }

    private var sessionSection: some View {
        Section {
            Toggle("Use a persistent session", isOn: $form.remoteSessionEnabled)

            if form.remoteSessionEnabled {
                Picker("Use", selection: $form.remoteSessionBackendIdentifier) {
                    ForEach(remoteSessionBackends, id: \.identifier) { backend in
                        RemoteSessionBackendLabel(backend: backend)
                            .tag(backend.identifier)
                            .disabled(
                                hasCustomStartupCommand
                                    && backend.managedStartupCommandSupport == .unsupported
                            )
                    }
                }

                Picker("On connect", selection: $form.remoteSessionStartupBehavior) {
                    ForEach(RemoteSessionStartupBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

            }
        } header: {
            sectionHeader("Session Persistence")
        } footer: {
            if form.remoteSessionEnabled {
                if let backend = unsupportedManagedStartupBackend {
                    Text(
                        String(
                            format: String(
                                localized: "%@ does not support custom startup commands yet."
                            ),
                            backend.displayName
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                } else {
                    Text(form.remoteSessionStartupBehavior.descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var securitySection: some View {
        Section {
            Toggle(
                String(format: String(localized: "Require %@ to open this server"), appLockManager.biometryDisplayName),
                isOn: $form.requiresBiometricUnlock
            )
            .disabled(!appLockManager.isBiometryAvailable && !form.requiresBiometricUnlock)

            if !appLockManager.isBiometryAvailable,
               let message = appLockManager.biometryAvailabilityMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let teleportModel,
               teleportModel.profile == activeTeleportProfile,
               teleportModel.discovery?.authenticationType == "local" {
                TeleportDeviceCredentialControls(model: teleportModel)
            }
        } header: {
            sectionHeader("Security")
        }
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $form.notes)
                .frame(minHeight: 56)
                #if os(iOS)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                #endif
        } header: {
            sectionHeader("Notes")
        }
    }

    private var advancedSection: some View {
        Section {
            Toggle("Auto Wake-on-LAN", isOn: $form.autoWakeOnLANEnabled)
                .accessibilityIdentifier("vvterm.serverForm.wakeOnLAN.enabled")
        } header: {
            sectionHeader("Advanced")
                .accessibilityIdentifier("vvterm.serverForm.advanced")
        } footer: {
            Text("For servers on the same local network.")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = operationFailureMessage {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Key Input View

    @ViewBuilder
    private var keyInputView: some View {
        // Stored keys picker
        if !operations.storedKeys.isEmpty {
            Picker("Stored Key", selection: selectedStoredKeyIDBinding) {
                Text("Select a key...").tag(nil as UUID?)
                ForEach(operations.storedKeys) { key in
                    HStack {
                        Image(systemName: key.hasPassphrase ? "lock.shield.fill" : "key.fill")
                        Text(key.name)
                    }
                    .tag(key.id as UUID?)
                }
            }
        }

        Button("Add to Keychain") {
            showingAddKeySheet = true
        }
    }

    private var selectedStoredKeyIDBinding: Binding<UUID?> {
        Binding(
            get: { operations.selectedStoredKeyID },
            set: { selectedID in
                guard let selectedID else {
                    operations.clearStoredKeySelection()
                    return
                }
                operations.selectStoredKey(id: selectedID) { loadedKey in
                    applyStoredKey(loadedKey)
                }
            }
        )
    }

    private func applyStoredKey(_ loadedKey: ServerFormStoredKeyLoad) {
        if let privateKey = loadedKey.privateKey {
            if form.sshKey != privateKey {
                programmaticSSHKeyValue = privateKey
            }
            form.sshKey = privateKey
        }
        if let passphrase = loadedKey.passphrase {
            form.sshPassphrase = passphrase
        }
        form.sshPublicKey = loadedKey.publicKey
    }

    private func updateTeleportProfile() {
        guard let profile = activeTeleportProfile, let teleportAccess else {
            teleportModel?.cancel()
            teleportModel = nil
            return
        }
        if teleportModel?.profile != profile {
            teleportModel?.cancel()
            teleportModel = TeleportProfileModel(profile: profile, service: teleportAccess)
        }
    }

    // MARK: - Connection Test

    private func resetConnectionTestState() {
        operations.resetConnectionTest()
    }

    private func handleCredentialIntentChange() {
        operations.invalidateCredentialLoading()
        resetConnectionTestState()
    }

    private func buildServer(id: UUID, createdAt: Date) -> Server {
        intent.preservingSourceMetadata(
            in: form.makeServer(
                id: id,
                workspaceID: selectedWorkspace?.id
                    ?? assignmentWorkspaces.first?.id
                    ?? stateStore.workspaces.first?.id
                    ?? makeID(),
                createdAt: createdAt
            )
        )
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        #else
        Text(title)
        #endif
    }

    private func applyPrefill(_ prefill: ServerFormPrefill) {
        form.applyPrefill(
            name: prefill.name,
            host: prefill.host,
            port: prefill.port,
            username: prefill.username
        )
        resetConnectionTestState()
    }

    private func reconcileAssignmentWorkspace() {
        if form.workspaceID == nil {
            form.workspaceID = assignmentWorkspaces.first?.id
        }

        guard let selectedWorkspace else { return }

        form.environment = ServerMoveSupport.resolveEnvironment(
            currentEnvironment: sourceServer?.environment ?? form.environment,
            preferredEnvironment: form.environment,
            destination: selectedWorkspace
        )
    }

    private func runConnectionTest(force: Bool) async {
        if let sourceServer {
            guard await appLockManager.authorizeProtectedServerAction(
                sourceServer,
                action: .testConnection
            ) else { return }
        }

        let snapshot = form.connectionSnapshot
        guard force || !operations.hasCompletedConnectionTest(for: snapshot) else { return }
        let serverID = intent.serverID(makeID: makeID)
        operations.startConnectionTest(
            server: buildServer(id: serverID, createdAt: intent.createdAt(now: now)),
            credentials: form.makeCredentials(serverID: serverID),
            snapshot: snapshot,
            onDetectedSystem: { identity in
                form.applyDetectedSystemIdentity(identity)
            }
        )
    }

    private func rejectHostKeyChallenge() {
        operations.rejectHostKeyChallenge()
    }

    private func approveHostKeyChallengeAndRetest() {
        guard operations.approveHostKeyChallenge() else { return }
        Task {
            await runConnectionTest(force: true)
        }
    }

    func saveServer() {
        let serverID = intent.serverID(makeID: makeID)
        let wakeOnLANSavePlan = form.wakeOnLANSavePlan(
            existingServer: intent.editedServer
        )
        let newServer = buildServer(
            id: serverID,
            createdAt: intent.createdAt(now: now)
        )
        operations.save(
            mutation: intent.mutation(for: newServer),
            credentials: form.makeCredentials(serverID: serverID),
            systemDetection: form.transportSelection != .teleport
                && form.iconSelection == .automatic
                && !operations.hasCompletedConnectionTest(for: form.connectionSnapshot)
                ? .attempt
                : .skip,
            wakeOnLANPlan: wakeOnLANSavePlan,
            hasProAccess: storeManager.allowsProFeatures,
            authorize: {
                guard let editedServer = intent.editedServer else { return true }
                return await appLockManager.authorizeProtectedServerAction(
                    editedServer,
                    action: .save
                )
            },
            onSaved: { savedServer in
                onSave(savedServer)
                dismiss()
            }
        )
    }

    private var operationFailureMessage: String? {
        if let connectionTestFailure = operations.connectionTestFailure {
            return connectionTestFailure.message
        }
        guard let failure = operations.failure else { return nil }
        switch failure {
        case .operation(let message):
            return message
        case .credentialLoad(let message):
            return String(
                format: String(localized: "Failed to load credentials: %@"),
                message
            )
        case .storedKeyLoad(let message):
            return String(
                format: String(localized: "Failed to load key: %@"),
                message
            )
        case .wakeOnLANUnavailable:
            return String(
                localized: "Could not detect the server's MAC address. Make sure it is online, then try again."
            )
        }
    }

    private func presentLocalDiscovery() {
        guard localDiscoveryPresentation == nil else { return }
        localDiscoveryPresentation = LocalDeviceDiscoveryPresentation(
            makeManager: makeLocalDiscoveryManager
        )
    }
}

struct MoveServerSheet: View {
    let serverManager: ServerManager
    @ObservedObject private var stateStore: ServerStateStore
    @EnvironmentObject private var storeManager: StoreManager
    let server: Server
    let preferredDestination: Workspace?
    let onMove: (Server) -> Void

    @Environment(\.dismiss) var dismiss

    @State private var selectedWorkspaceId: UUID?
    @State private var selectedEnvironment: ServerEnvironment
    @State var isMoving = false
    @State private var error: String?
    @State private var showingUpgrade = false
    @State private var showingCreateWorkspace = false

    init(
        serverManager: ServerManager,
        server: Server,
        preferredDestination: Workspace? = nil,
        onMove: @escaping (Server) -> Void
    ) {
        self.serverManager = serverManager
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
        self.server = server
        self.preferredDestination = preferredDestination
        self.onMove = onMove
        _selectedWorkspaceId = State(initialValue: preferredDestination?.id)
        _selectedEnvironment = State(initialValue: server.environment)
    }

    private var currentWorkspace: Workspace? {
        stateStore.workspace(withID: server.workspaceId)
    }

    private var destinationWorkspaces: [Workspace] {
        let destinations = stateStore.moveDestinations(
            for: server,
            hasProAccess: storeManager.allowsProFeatures
        )
        guard let preferredDestination,
              destinations.contains(where: { $0.id == preferredDestination.id }) else {
            return destinations
        }

        return destinations.sorted { lhs, rhs in
            if lhs.id == preferredDestination.id { return true }
            if rhs.id == preferredDestination.id { return false }
            return lhs.order < rhs.order
        }
    }

    private var selectedDestination: Workspace? {
        if let selectedWorkspaceId,
           let matchingDestination = destinationWorkspaces.first(where: { $0.id == selectedWorkspaceId }) {
            return matchingDestination
        }

        return destinationWorkspaces.first
    }

    var moveButtonDisabled: Bool {
        isMoving || selectedDestination == nil
    }

    private var destinationAvailabilityNotice: String {
        if stateStore.workspaces.count <= 1 {
            if storeManager.allowsProFeatures {
                return String(localized: "No additional workspaces yet. Create one to move this server.")
            }

            return String(localized: "No additional workspaces yet. Create another workspace to move this server. Multiple workspaces are available on Pro.")
        }

        return String(localized: "No additional workspace is available for this server right now.")
    }

    private var environmentNotice: String? {
        guard let selectedDestination,
              stateStore.moveRequiresEnvironmentFallback(server, destination: selectedDestination) else {
            return nil
        }

        let resolvedEnvironment = stateStore.resolvedEnvironment(
            for: server,
            destination: selectedDestination,
            preferredEnvironment: selectedEnvironment
        )

        return String(
            format: String(localized: "\"%@\" isn't available in %@. The server will use %@ there."),
            server.environment.displayName,
            selectedDestination.name,
            resolvedEnvironment.displayName
        )
    }

    var body: some View {
        platformBody
    }

    var formContent: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    Text(server.name)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("From") {
                    Text(currentWorkspace?.name ?? String(localized: "Current Workspace"))
                        .foregroundStyle(.secondary)
                }

                if destinationWorkspaces.isEmpty {
                    Button {
                        showingCreateWorkspace = true
                    } label: {
                        Label("Create Workspace", systemImage: "folder.badge.plus")
                    }
                } else {
                    Picker("Destination", selection: $selectedWorkspaceId) {
                        ForEach(destinationWorkspaces) { workspace in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.fromHex(workspace.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(workspace.name)
                            }
                            .tag(Optional(workspace.id))
                        }
                    }

                    Picker("Environment", selection: $selectedEnvironment) {
                        ForEach(selectedDestination?.environments ?? ServerEnvironment.builtInEnvironments) { env in
                            HStack {
                                Circle()
                                    .fill(env.color)
                                    .frame(width: 8, height: 8)
                                Text(env.displayName)
                            }
                            .tag(env)
                        }
                    }

                    if let environmentNotice {
                        Text(environmentNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                sectionHeader("Move")
            } footer: {
                if destinationWorkspaces.isEmpty {
                    Text(destinationAvailabilityNotice)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .interactiveDismissDisabled(isMoving)
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: selectedWorkspaceId) { _ in
            reconcileSelection()
        }
        .sheet(isPresented: $showingCreateWorkspace) {
            WorkspaceFormSheet(
                serverManager: serverManager,
                onSave: { workspace in
                    selectedWorkspaceId = workspace.id
                }
            )
            .adaptiveSoftScrollEdges()
        }
        .proUpgradePresentation(isPresented: $showingUpgrade, source: .workspaceLimit)
        .moveServerPlatformActions(
            isMoving: isMoving,
            moveButtonDisabled: moveButtonDisabled,
            onCancel: { dismiss() },
            onMove: moveServer
        )
        .adaptiveSoftScrollEdges()
    }

    private func reconcileSelection() {
        let hasValidSelection = selectedWorkspaceId.map { selectedId in
            destinationWorkspaces.contains(where: { $0.id == selectedId })
        } ?? false

        if !hasValidSelection {
            selectedWorkspaceId = preferredDestination?.id ?? destinationWorkspaces.first?.id
        }

        guard let selectedDestination else { return }

        selectedEnvironment = stateStore.resolvedEnvironment(
            for: server,
            destination: selectedDestination,
            preferredEnvironment: selectedEnvironment
        )
    }

    func moveServer() {
        guard let destination = selectedDestination else { return }

        isMoving = true
        error = nil

        Task {
            do {
                let updatedServer = try await serverManager.moveServer(
                    server,
                    to: destination,
                    preferredEnvironment: selectedEnvironment,
                    hasProAccess: storeManager.allowsProFeatures
                )

                await MainActor.run {
                    isMoving = false
                    onMove(updatedServer)
                    dismiss()
                }
            } catch let error as VVTermError {
                await MainActor.run {
                    isMoving = false
                    if case .proRequired = error {
                        showingUpgrade = true
                    } else {
                        self.error = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    isMoving = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        #else
        Text(title)
        #endif
    }
}
