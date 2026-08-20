import SwiftUI

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
    let server: Server?
    let prefill: ServerFormPrefill?
    let makeLocalDiscoveryManager: LocalSSHDiscoveryManagerFactory
    let onSave: (Server) -> Void

    @Environment(\.dismiss) var dismiss

    @State private var form: ServerFormModel
    @StateObject private var operations: ServerFormOperationController
    @State private var showCloudflareOverrides: Bool = false

    @State private var showingServerLimitAlert = false
    @State private var showingCreateWorkspace = false
    @State private var showingAddKeySheet = false
    @State private var programmaticSSHKeyValue: String?
    @State private var localDiscoveryPresentation: LocalDeviceDiscoveryPresentation?
    @State private var hasAuthorizedInitialEdit: Bool

    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    var isEditing: Bool { server != nil }

    private var hostKeyTrustRequest: ServerSecurityApprovalRequest? {
        operations.hostKeyChallenge.map(ServerSecurityApprovalRequest.hostKey)
    }

    init(
        serverManager: ServerManager,
        workspace: Workspace?,
        server: Server? = nil,
        prefill: ServerFormPrefill? = nil,
        dependencies: ServerFormDependencies,
        makeLocalDiscoveryManager: @escaping LocalSSHDiscoveryManagerFactory,
        onSave: @escaping (Server) -> Void
    ) {
        self.serverManager = serverManager
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
        self.workspace = workspace
        self.server = server
        self.prefill = prefill
        self.makeLocalDiscoveryManager = makeLocalDiscoveryManager
        self.now = dependencies.now
        self.makeID = dependencies.makeID
        let saveUseCase = ServerSaveUseCase(mutations: serverManager)
        self.onSave = onSave
        _operations = StateObject(
            wrappedValue: ServerFormOperationController(
                credentialLoader: ServerFormCredentialLoader(
                    repository: dependencies.credentials
                ),
                connectionTester: dependencies.connectionTester,
                hostKeys: dependencies.hostKeys,
                saveUseCase: saveUseCase,
                now: dependencies.now,
                makeID: dependencies.makeID
            )
        )

        var initialForm = ServerFormModel(
            server: server,
            workspaceID: workspace?.id,
            defaultTmuxEnabled: dependencies.defaultTmuxEnabled(),
            defaultTmuxStartupBehavior: dependencies.defaultTmuxStartupBehavior()
        )
        if server == nil, let prefill {
            initialForm.applyPrefill(
                name: prefill.name,
                host: prefill.host,
                port: prefill.port,
                username: prefill.username
            )
        }
        _form = State(initialValue: initialForm)
        _hasAuthorizedInitialEdit = State(initialValue: server?.requiresBiometricUnlock != true)
        _showCloudflareOverrides = State(
            initialValue: !(server?.cloudflareTeamDomainOverride ?? "").isEmpty
        )
    }

    private var serverCount: Int {
        stateStore.servers.count
    }

    private var isAtLimit: Bool {
        !isEditing && !stateStore.canAddServer(hasProAccess: storeManager.allowsProFeatures)
    }

    private var assignmentWorkspaces: [Workspace] {
        stateStore.assignmentWorkspaces(for: server, hasProAccess: storeManager.allowsProFeatures)
    }

    private var selectedWorkspace: Workspace? {
        if let workspaceID = form.workspaceID,
           let matchingWorkspace = assignmentWorkspaces.first(where: { $0.id == workspaceID }) {
            return matchingWorkspace
        }

        return assignmentWorkspaces.first
    }

    private var workspaceEnvironmentNotice: String? {
        guard let server,
              let selectedWorkspace,
              selectedWorkspace.id != server.workspaceId,
              stateStore.moveRequiresEnvironmentFallback(server, destination: selectedWorkspace) else {
            return nil
        }

        let resolvedEnvironment = stateStore.resolvedEnvironment(
            for: server,
            destination: selectedWorkspace,
            preferredEnvironment: form.environment
        )

        return String(
            format: String(localized: "\"%@\" isn't available in %@. The server will use %@ there."),
            server.environment.displayName,
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

    private var hasValidConnectionTest: Bool {
        operations.hasValidConnectionTest(for: form.connectionSnapshot)
    }

    var isSaving: Bool { operations.isSaving }

    private var isLoadingCredentials: Bool { operations.isLoadingCredentials }

    private var isTestingConnection: Bool { operations.isTestingConnection }

    var saveButtonDisabled: Bool {
        !form.isValid || isSaving || isAtLimit || isLoadingCredentials || isTestingConnection
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
                .opacity(hasAuthorizedInitialEdit ? 1 : 0)
                .allowsHitTesting(hasAuthorizedInitialEdit)
                .accessibilityHidden(!hasAuthorizedInitialEdit)

            if !hasAuthorizedInitialEdit {
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
        connectionSection
        sessionSection
    }

    @ViewBuilder
    private var detailFormSections: some View {
        securitySection
        assignmentSection
        notesSection
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
            if let server {
                guard await appLockManager.authorizeProtectedServerAction(server, action: .edit) else {
                    dismiss()
                    return
                }
                hasAuthorizedInitialEdit = true
            }
            operations.loadFormCredentials(for: server) { credentials in
                if let privateKey = credentials.privateKey,
                   let key = String(data: privateKey, encoding: .utf8) {
                    programmaticSSHKeyValue = key
                }
                guard let server else { return }
                form.apply(credentials, for: server)
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
                    applyPrefill(ServerFormPrefill(discoveredHost: discoveredHost))
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
            .onAppear {
                reconcileAssignmentWorkspace()
            }
            .onChange(of: operations.connectionTestFailure) { failure in
                if failure?.requiresCloudflareOverrides == true {
                    showCloudflareOverrides = true
                }
            }
            .onDisappear {
                operations.cancel()
            }
            .onChange(of: form.host) { _ in resetConnectionTestState() }
            .onChange(of: form.port) { _ in resetConnectionTestState() }
            .onChange(of: form.eternalTerminalPort) { _ in resetConnectionTestState() }
            .onChange(of: form.username) { _ in resetConnectionTestState() }
            .onChange(of: form.transportSelection) { _ in handleCredentialIntentChange() }
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
                #if os(iOS)
                .textContentType(.name)
                #endif

            HStack(spacing: 12) {
                TextField("Host", text: $form.host, prompt: Text(String(localized: "203.0.113.10")))
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
        } header: {
            sectionHeader("Server")
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section {
            Picker("Transport", selection: $form.transportSelection) {
                ForEach(ServerTransportSelection.allCases) { transport in
                    Label(transport.displayName, systemImage: transport.icon)
                        .tag(transport)
                }
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

            if form.transportSelection != .tailscale {
                Picker("Method", selection: $form.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Label(method.displayName, systemImage: method.icon)
                            .tag(method)
                    }
                }

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
            } else {
                Text(String(localized: "Uses server-side Tailscale SSH policy. No password or SSH key is required."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Authentication")
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                Task {
                    await runConnectionTest(force: true)
                }
            } label: {
                Text(String(localized: "Test Connection"))
                    .opacity(isTestingConnection ? 0 : 1)
                    .overlay {
                        if isTestingConnection {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text(String(localized: "Testing..."))
                            }
                        }
                    }
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .controlSize(.regular)
            .disabled(!form.isValid || isTestingConnection)
        } header: {
            sectionHeader("Connection")
        } footer: {
            connectionFooter
        }
    }

    private var sessionSection: some View {
        Section {
            Toggle("Use tmux to preserve sessions", isOn: $form.tmuxEnabled)

            if form.tmuxEnabled {
                Picker("On connect", selection: $form.tmuxStartupBehavior) {
                    ForEach(TmuxStartupBehavior.configCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(form.tmuxStartupBehavior.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Session")
        } footer: {
            Text("Sessions stay alive across app restarts and disconnects when tmux is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    private var connectionFooter: some View {
        if hasValidConnectionTest {
            Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if let connectionTestError = operations.connectionTestFailure?.message {
            Text(connectionTestError)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

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

    // MARK: - Connection Test

    private func resetConnectionTestState() {
        operations.resetConnectionTest()
    }

    private func handleCredentialIntentChange() {
        operations.invalidateCredentialLoading()
        resetConnectionTestState()
    }

    private func buildServer(id: UUID, createdAt: Date) -> Server {
        form.makeServer(
            id: id,
            workspaceID: selectedWorkspace?.id
                ?? assignmentWorkspaces.first?.id
                ?? stateStore.workspaces.first?.id
                ?? makeID(),
            createdAt: createdAt
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
            currentEnvironment: server?.environment ?? form.environment,
            preferredEnvironment: form.environment,
            destination: selectedWorkspace
        )
    }

    private func runConnectionTest(force: Bool) async {
        if let server {
            guard await appLockManager.authorizeProtectedServerAction(
                server,
                action: .testConnection
            ) else { return }
        }

        let snapshot = form.connectionSnapshot
        guard force || !operations.hasValidConnectionTest(for: snapshot) else { return }
        let serverID = server?.id ?? makeID()
        operations.startConnectionTest(
            server: buildServer(id: serverID, createdAt: server?.createdAt ?? now()),
            credentials: form.makeCredentials(serverID: serverID),
            snapshot: snapshot
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
        let serverID = server?.id ?? makeID()
        let newServer = buildServer(id: serverID, createdAt: server?.createdAt ?? now())
        operations.save(
            mutation: isEditing ? .update(newServer) : .create(newServer),
            credentials: form.makeCredentials(serverID: serverID),
            hasProAccess: storeManager.allowsProFeatures,
            authorize: {
                guard let server else { return true }
                return await appLockManager.authorizeProtectedServerAction(server, action: .save)
            },
            onSaved: { savedServer in
                onSave(savedServer)
                dismiss()
            }
        )
    }

    private var operationFailureMessage: String? {
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
