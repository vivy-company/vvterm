import SwiftUI
#if os(iOS)
import UIKit
#endif

enum ServerTransportSelection: String, CaseIterable, Identifiable, Equatable {
    case standard
    case tailscale
    case mosh
    case cloudflare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return String(localized: "SSH")
        case .tailscale:
            return String(localized: "Tailscale")
        case .mosh:
            return String(localized: "Mosh")
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
        case .cloudflare:
            return "shield.lefthalf.filled"
        }
    }

    var connectionMode: SSHConnectionMode {
        switch self {
        case .standard:
            return .standard
        case .tailscale:
            return .tailscale
        case .mosh:
            return .mosh
        case .cloudflare:
            return .cloudflare
        }
    }

    init(server: Server) {
        switch server.connectionMode {
        case .tailscale:
            self = .tailscale
        case .mosh:
            self = .mosh
        case .cloudflare:
            self = .cloudflare
        case .standard:
            self = .standard
        }
    }
}

struct ServerFormCredentialBuilder {
    static func build(
        serverId: UUID,
        transportSelection: ServerTransportSelection,
        authMethod: AuthMethod,
        password: String,
        sshKey: String,
        sshPassphrase: String,
        sshPublicKey: String,
        cloudflareAccessMode: CloudflareAccessMode?,
        cloudflareClientID: String,
        cloudflareClientSecret: String
    ) -> ServerCredentials {
        var credentials = ServerCredentials(serverId: serverId)

        guard transportSelection != .tailscale else {
            return credentials
        }

        switch authMethod {
        case .password:
            credentials.password = password
        case .sshKey:
            credentials.sshKey = sshKey.data(using: .utf8)
            if !sshPublicKey.isEmpty {
                credentials.publicKey = sshPublicKey.data(using: .utf8)
            }
        case .sshKeyWithPassphrase:
            credentials.sshKey = sshKey.data(using: .utf8)
            credentials.sshPassphrase = sshPassphrase
            if !sshPublicKey.isEmpty {
                credentials.publicKey = sshPublicKey.data(using: .utf8)
            }
        }

        if transportSelection == .cloudflare, cloudflareAccessMode == .serviceToken {
            let clientID = cloudflareClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientSecret = cloudflareClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            credentials.cloudflareClientID = clientID.isEmpty ? nil : clientID
            credentials.cloudflareClientSecret = clientSecret.isEmpty ? nil : clientSecret
        }

        return credentials
    }
}

// MARK: - Server Form Sheet

struct ServerFormSheet: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject private var storeManager = StoreManager.shared
    let workspace: Workspace?
    let server: Server?
    let onSave: (Server) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var transportSelection: ServerTransportSelection = .standard
    @State private var selectedAuthMethod: AuthMethod = .password
    @State private var password: String = ""
    @State private var sshKey: String = ""
    @State private var sshPassphrase: String = ""
    @State private var sshPublicKey: String = ""
    @State private var selectedCloudflareAccessMode: CloudflareAccessMode = .oauth
    @State private var cloudflareClientID: String = ""
    @State private var cloudflareClientSecret: String = ""
    @State private var cloudflareTeamDomainOverride: String = ""
    @State private var showCloudflareOverrides: Bool = false
    @State private var selectedEnvironment: ServerEnvironment = .production
    @State private var notes: String = ""
    @State private var tmuxEnabled: Bool = true
    @State private var tmuxStartupBehavior: TmuxStartupBehavior = .vvtermManaged

    @State private var showingServerLimitAlert = false
    @State private var showingAddKeySheet = false
    @State private var isSaving = false
    @State private var isLoadingCredentials = false
    @State private var error: String?
    @State private var storedKeys: [SSHKeyEntry] = []
    @State private var selectedStoredKey: SSHKeyEntry?
    @State private var isApplyingStoredKey = false
    @State private var isTestingConnection = false
    @State private var connectionTestError: String?
    @State private var connectionTestSucceeded = false
    @State private var lastTestSnapshot: ConnectionTestSnapshot?

    private var isEditing: Bool { server != nil }

    init(
        serverManager: ServerManager,
        workspace: Workspace?,
        server: Server? = nil,
        onSave: @escaping (Server) -> Void
    ) {
        self.serverManager = serverManager
        self.workspace = workspace
        self.server = server
        self.onSave = onSave

        if let server = server {
            _name = State(initialValue: server.name)
            _host = State(initialValue: server.host)
            _port = State(initialValue: String(server.port))
            _username = State(initialValue: server.username)
            _transportSelection = State(initialValue: ServerTransportSelection(server: server))
            _selectedAuthMethod = State(initialValue: server.authMethod)
            _selectedCloudflareAccessMode = State(initialValue: server.cloudflareAccessMode ?? .oauth)
            _cloudflareTeamDomainOverride = State(initialValue: server.cloudflareTeamDomainOverride ?? "")
            _showCloudflareOverrides = State(
                initialValue: !(server.cloudflareTeamDomainOverride ?? "").isEmpty
            )
            _selectedEnvironment = State(initialValue: server.environment)
            _notes = State(initialValue: server.notes ?? "")
            _tmuxEnabled = State(initialValue: server.tmuxEnabledOverride ?? Self.defaultTmuxEnabled())
            _tmuxStartupBehavior = State(initialValue: server.tmuxStartupBehaviorOverride ?? Self.defaultTmuxStartupBehavior())
        } else {
            _tmuxEnabled = State(initialValue: Self.defaultTmuxEnabled())
            _tmuxStartupBehavior = State(initialValue: Self.defaultTmuxStartupBehavior())
        }
    }

    private var serverCount: Int {
        serverManager.servers.count
    }

    private var isAtLimit: Bool {
        !isEditing && !serverManager.canAddServer
    }

    private struct ConnectionTestSnapshot: Equatable {
        let host: String
        let port: String
        let username: String
        let transportSelection: ServerTransportSelection
        let authMethod: AuthMethod
        let password: String
        let sshKey: String
        let sshPassphrase: String
        let sshPublicKey: String
        let cloudflareAccessMode: CloudflareAccessMode
        let cloudflareClientID: String
        let cloudflareClientSecret: String
        let cloudflareTeamDomainOverride: String
    }

    private var connectionSnapshot: ConnectionTestSnapshot {
        ConnectionTestSnapshot(
            host: host,
            port: port,
            username: effectiveUsername,
            transportSelection: transportSelection,
            authMethod: selectedAuthMethod,
            password: password,
            sshKey: sshKey,
            sshPassphrase: sshPassphrase,
            sshPublicKey: sshPublicKey,
            cloudflareAccessMode: selectedCloudflareAccessMode,
            cloudflareClientID: cloudflareClientID,
            cloudflareClientSecret: cloudflareClientSecret,
            cloudflareTeamDomainOverride: cloudflareTeamDomainOverride
        )
    }

    private var hasValidConnectionTest: Bool {
        connectionTestSucceeded && lastTestSnapshot == connectionSnapshot
    }

    var body: some View {
        #if os(iOS)
        formContent
        #else
        NavigationStack {
            formContent
        }
        #endif
    }

    private var formContent: some View {
        Form {
            limitSection
            serverSection
            authSection
            connectionSection
            sessionSection
            environmentSection
            notesSection
            errorSection
        }
        .formStyle(.grouped)
        #if os(iOS)
        .environment(\.defaultMinListRowHeight, 34)
        .modifier(CompactListSectionSpacingModifier())
        .modifier(TransparentNavigationBarModifier())
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarAppearance(
                backgroundColor: .clear,
                isTranslucent: true,
                shadowColor: .clear
            )
        #endif
        .navigationTitle(isEditing ? String(localized: "Edit Server") : String(localized: "Add Server"))
        .interactiveDismissDisabled(isSaving)
        .task {
            // Load credentials from keychain when editing
            guard let server = server else { return }
            isLoadingCredentials = true
            defer { isLoadingCredentials = false }

            do {
                let credentials = try KeychainManager.shared.getCredentials(for: server)

                if server.connectionMode != .tailscale {
                    switch server.authMethod {
                    case .password:
                        if let pwd = credentials.password {
                            password = pwd
                        }
                    case .sshKey:
                        if let keyData = credentials.privateKey,
                           let keyString = String(data: keyData, encoding: .utf8) {
                            sshKey = keyString
                        }
                    case .sshKeyWithPassphrase:
                        if let keyData = credentials.privateKey,
                           let keyString = String(data: keyData, encoding: .utf8) {
                            sshKey = keyString
                        }
                        if let phrase = credentials.passphrase {
                            sshPassphrase = phrase
                        }
                    }
                }
                if let publicKeyData = credentials.publicKey,
                   let publicKeyString = String(data: publicKeyData, encoding: .utf8) {
                    sshPublicKey = publicKeyString
                } else {
                    sshPublicKey = ""
                }

                cloudflareClientID = credentials.cloudflareClientID ?? ""
                cloudflareClientSecret = credentials.cloudflareClientSecret ?? ""
            } catch {
                self.error = String(format: String(localized: "Failed to load credentials: %@"), error.localizedDescription)
            }

        }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveServer()
                    } label: {
                        #if os(macOS)
                        if isSaving {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(String(localized: "Saving..."))
                            }
                        } else {
                            Text(isEditing ? String(localized: "Save") : String(localized: "Add"))
                        }
                        #else
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(isEditing ? String(localized: "Save") : String(localized: "Add"))
                        }
                        #endif
                    }
                    .disabled(!isValid || isSaving || isAtLimit || isLoadingCredentials || isTestingConnection)
                }
            }
            .sheet(isPresented: $showingAddKeySheet) {
                AddSSHKeySheet(onSave: { entry in
                    storedKeys = KeychainManager.shared.getStoredSSHKeys()
                    selectedStoredKey = entry
                    loadStoredKey(entry)
                })
            }
            .limitReachedAlert(.servers, isPresented: $showingServerLimitAlert)
            .onAppear {
                storedKeys = KeychainManager.shared.getStoredSSHKeys()
            }
            .onChange(of: host) { _ in resetConnectionTestState() }
            .onChange(of: port) { _ in resetConnectionTestState() }
            .onChange(of: username) { _ in resetConnectionTestState() }
            .onChange(of: transportSelection) { _ in resetConnectionTestState() }
            .onChange(of: selectedAuthMethod) { _ in resetConnectionTestState() }
            .onChange(of: password) { _ in resetConnectionTestState() }
            .onChange(of: sshKey) { _ in
                if !isLoadingCredentials && !isApplyingStoredKey {
                    selectedStoredKey = nil
                    sshPublicKey = ""
                }
                resetConnectionTestState()
            }
            .onChange(of: sshPassphrase) { _ in resetConnectionTestState() }
            .onChange(of: sshPublicKey) { _ in resetConnectionTestState() }
            .onChange(of: selectedCloudflareAccessMode) { _ in resetConnectionTestState() }
            .onChange(of: cloudflareClientID) { _ in resetConnectionTestState() }
            .onChange(of: cloudflareClientSecret) { _ in resetConnectionTestState() }
            .onChange(of: cloudflareTeamDomainOverride) { _ in resetConnectionTestState() }
    }

    @ViewBuilder
    private var limitSection: some View {
        if isAtLimit {
            Section {
                ProLimitBanner(
                    title: String(localized: "Server Limit Reached"),
                    message: String(format: String(localized: "You've reached the limit of %lld servers. Upgrade to Pro for unlimited servers."), Int64(FreeTierLimits.maxServers))
                ) {
                    showingServerLimitAlert = true
                }
            }
        } else if !isEditing && !storeManager.isPro {
            Section {
                UsageIndicator(
                    current: serverCount,
                    limit: FreeTierLimits.maxServers,
                    label: String(localized: "Servers"),
                    showUpgrade: $showingServerLimitAlert
                )
            }
        }
    }

    private var serverSection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text(String(localized: "My Server")))
                #if os(iOS)
                .textContentType(.name)
                #endif

            HStack(spacing: 12) {
                TextField("Host", text: $host, prompt: Text(String(localized: "203.0.113.10")))
                    #if os(iOS)
                    .textContentType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif

                TextField("Port", text: $port, prompt: Text(String(localized: "22")))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76)
            }

            TextField("Username", text: $username, prompt: Text(String(localized: "root")))
                #if os(iOS)
                .textContentType(.username)
                #endif
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            sectionHeader("Server")
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section {
            Picker("Transport", selection: $transportSelection) {
                ForEach(ServerTransportSelection.allCases) { transport in
                    Label(transport.displayName, systemImage: transport.icon)
                        .tag(transport)
                }
            }

            if transportSelection == .cloudflare {
                Picker("Cloudflare Access", selection: $selectedCloudflareAccessMode) {
                    ForEach(CloudflareAccessMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                switch selectedCloudflareAccessMode {
                case .oauth:
                    Text(String(localized: "OAuth login will open in browser. Team/App domain values are auto-discovered from host."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showCloudflareOverrides {
                        TextField("Team Domain Override", text: $cloudflareTeamDomainOverride, prompt: Text("team.cloudflareaccess.com"))
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
                    TextField("Service Token Client ID", text: $cloudflareClientID, prompt: Text(String(localized: "Required")))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Service Token Client Secret", text: $cloudflareClientSecret, prompt: Text(String(localized: "Required")))
                }
            }

            if transportSelection != .tailscale {
                Picker("Method", selection: $selectedAuthMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Label(method.displayName, systemImage: method.icon)
                            .tag(method)
                    }
                }

                switch selectedAuthMethod {
                case .password:
                    SecureField("Password", text: $password, prompt: Text(String(localized: "Required")))
                        #if os(iOS)
                        .textContentType(.password)
                        #endif

                case .sshKey:
                    keyInputView

                case .sshKeyWithPassphrase:
                    keyInputView
                    SecureField("Key Passphrase", text: $sshPassphrase, prompt: Text(String(localized: "Optional")))
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
            .disabled(!isValid || isTestingConnection)
        } header: {
            sectionHeader("Connection")
        } footer: {
            connectionFooter
        }
    }

    private var sessionSection: some View {
        Section {
            Toggle("Use tmux to preserve sessions", isOn: $tmuxEnabled)

            if tmuxEnabled {
                Picker("On connect", selection: $tmuxStartupBehavior) {
                    ForEach(TmuxStartupBehavior.serverConfigCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }
        } header: {
            sectionHeader("Session")
        } footer: {
            Text("Sessions stay alive across app restarts and disconnects when tmux is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var environmentSection: some View {
        Section {
            Picker("Environment", selection: $selectedEnvironment) {
                ForEach(workspace?.environments ?? ServerEnvironment.builtInEnvironments) { env in
                    HStack {
                        Circle()
                            .fill(env.color)
                            .frame(width: 8, height: 8)
                        Text(env.displayName)
                    }
                    .tag(env)
                }
            }
        } header: {
            sectionHeader("Environment")
        }
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $notes)
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
        if let error = error {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    #if os(iOS)
    private struct CompactListSectionSpacingModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 17.0, *) {
                content.listSectionSpacing(.compact)
            } else {
                content
            }
        }
    }

    private struct TransparentNavigationBarModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 16.0, *) {
                content.toolbarBackground(.hidden, for: .navigationBar)
            } else {
                content
            }
        }
    }
    #endif

    // MARK: - Key Input View

    @ViewBuilder
    private var connectionFooter: some View {
        if connectionTestSucceeded && hasValidConnectionTest {
            Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if let connectionTestError {
            Text(connectionTestError)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var keyInputView: some View {
        // Stored keys picker
        if !storedKeys.isEmpty {
            Picker("Stored Key", selection: $selectedStoredKey) {
                Text("Select a key...").tag(nil as SSHKeyEntry?)
                ForEach(storedKeys) { key in
                    HStack {
                        Image(systemName: key.hasPassphrase ? "lock.shield.fill" : "key.fill")
                        Text(key.name)
                    }
                    .tag(key as SSHKeyEntry?)
                }
            }
            .onChange(of: selectedStoredKey) { newKey in
                if let key = newKey {
                    loadStoredKey(key)
                }
            }
        }

        Button("Add to Keychain") {
            showingAddKeySheet = true
        }
    }

    private func loadStoredKey(_ entry: SSHKeyEntry) {
        do {
            isApplyingStoredKey = true
            defer { isApplyingStoredKey = false }
            if let keyData = try KeychainManager.shared.getStoredSSHKeyData(for: entry.id) {
                if let keyString = String(data: keyData.key, encoding: .utf8) {
                    sshKey = keyString
                }
                if let passphrase = keyData.passphrase {
                    sshPassphrase = passphrase
                }
            }
            sshPublicKey = entry.publicKey ?? ""
        } catch {
            self.error = String(format: String(localized: "Failed to load key: %@"), error.localizedDescription)
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !name.isEmpty &&
        !host.isEmpty &&
        Int(port) != nil &&
        hasValidCredentials
    }

    private var hasValidCredentials: Bool {
        guard transportSelection != .tailscale else {
            return true
        }

        if transportSelection == .cloudflare {
            switch selectedCloudflareAccessMode {
            case .oauth:
                break
            case .serviceToken:
                guard !cloudflareClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !cloudflareClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
            }
        }

        switch selectedAuthMethod {
        case .password:
            return !password.isEmpty
        case .sshKey:
            return !sshKey.isEmpty
        case .sshKeyWithPassphrase:
            return !sshKey.isEmpty && !sshPassphrase.isEmpty
        }
    }

    // MARK: - Connection Test

    private func resetConnectionTestState() {
        connectionTestError = nil
        connectionTestSucceeded = false
        lastTestSnapshot = nil
    }

    private func buildServer(id: UUID, createdAt: Date) -> Server {
        let portNum = Int(port) ?? 22
        return Server(
            id: id,
            workspaceId: workspace?.id ?? serverManager.workspaces.first?.id ?? UUID(),
            environment: selectedEnvironment,
            name: name,
            host: host,
            port: portNum,
            username: effectiveUsername,
            connectionMode: transportSelection.connectionMode,
            authMethod: transportSelection == .tailscale ? .password : selectedAuthMethod,
            cloudflareAccessMode: transportSelection == .cloudflare ? selectedCloudflareAccessMode : nil,
            cloudflareTeamDomainOverride: transportSelection == .cloudflare ? normalizedCloudflareOverride(cloudflareTeamDomainOverride) : nil,
            cloudflareAppDomainOverride: nil,
            notes: notes.isEmpty ? nil : notes,
            tmuxEnabledOverride: tmuxEnabled,
            tmuxStartupBehaviorOverride: tmuxStartupBehavior,
            tmuxRememberedSessionName: server?.tmuxRememberedSessionName,
            createdAt: createdAt
        )
    }

    private var effectiveUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "root" : trimmed
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

    private static func defaultTmuxEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "terminalTmuxEnabledDefault") == nil {
            return true
        }
        return defaults.bool(forKey: "terminalTmuxEnabledDefault")
    }

    private static func defaultTmuxStartupBehavior() -> TmuxStartupBehavior {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: "terminalTmuxStartupBehaviorDefault") else {
            return .askEveryTime
        }
        return TmuxStartupBehavior(rawValue: rawValue) ?? .askEveryTime
    }

    private func buildCredentials(for serverId: UUID) -> ServerCredentials {
        ServerFormCredentialBuilder.build(
            serverId: serverId,
            transportSelection: transportSelection,
            authMethod: selectedAuthMethod,
            password: password,
            sshKey: sshKey,
            sshPassphrase: sshPassphrase,
            sshPublicKey: sshPublicKey,
            cloudflareAccessMode: transportSelection == .cloudflare ? selectedCloudflareAccessMode : nil,
            cloudflareClientID: cloudflareClientID,
            cloudflareClientSecret: cloudflareClientSecret
        )
    }

    private func normalizedCloudflareOverride(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runConnectionTest(force: Bool) async -> Bool {
        let snapshot = await MainActor.run { connectionSnapshot }
        let shouldSkip = await MainActor.run { !force && hasValidConnectionTest }
        if shouldSkip {
            return true
        }

        let (testServer, credentials) = await MainActor.run { () -> (Server, ServerCredentials) in
            isTestingConnection = true
            connectionTestError = nil
            connectionTestSucceeded = false

            let serverId = server?.id ?? UUID()
            let server = buildServer(id: serverId, createdAt: server?.createdAt ?? Date())
            let credentials = buildCredentials(for: serverId)
            return (server, credentials)
        }

        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            let client = SSHClient()
            do {
                _ = try await client.connect(to: testServer, credentials: credentials)
                if testServer.connectionMode == .mosh {
                    _ = try await RemoteMoshManager.shared.bootstrapConnectInfo(
                        using: client,
                        startCommand: "exec true",
                        portRange: 60001...61000
                    )
                }
                await client.disconnect()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        var success = false
        await MainActor.run {
            isTestingConnection = false
            lastTestSnapshot = snapshot

            switch result {
            case .success:
                connectionTestSucceeded = true
                success = true
            case .failure(let error):
                let baseMessage = error.localizedDescription
                if testServer.connectionMode == .tailscale {
                    let reminder = String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback).")
                    if baseMessage.contains(reminder) {
                        connectionTestError = baseMessage
                    } else {
                        connectionTestError = "\(baseMessage)\n\(reminder)"
                    }
                } else {
                    connectionTestError = baseMessage
                }
                if let sshError = error as? SSHError, case .cloudflareConfigurationRequired = sshError {
                    showCloudflareOverrides = true
                }
                connectionTestSucceeded = false
                success = false
            }
        }

        return success
    }

    private func saveServer() {
        isSaving = true
        error = nil

        Task {
            do {
                let (newServer, credentials) = await MainActor.run { () -> (Server, ServerCredentials) in
                    let serverId = server?.id ?? UUID()
                    let server = buildServer(id: serverId, createdAt: server?.createdAt ?? Date())
                    let credentials = buildCredentials(for: serverId)
                    return (server, credentials)
                }

                if isEditing {
                    try await serverManager.updateServer(newServer)
                    // Store credentials based on auth method
                    let publicKeyData = sshPublicKey.isEmpty ? nil : sshPublicKey.data(using: .utf8)
                    if transportSelection != .tailscale {
                        switch selectedAuthMethod {
                        case .password:
                            if !password.isEmpty {
                                try KeychainManager.shared.storePassword(for: newServer.id, password: password)
                            }
                        case .sshKey:
                            if !sshKey.isEmpty, let keyData = sshKey.data(using: .utf8) {
                                try KeychainManager.shared.storeSSHKey(for: newServer.id, privateKey: keyData, passphrase: nil, publicKey: publicKeyData)
                            }
                        case .sshKeyWithPassphrase:
                            if !sshKey.isEmpty, let keyData = sshKey.data(using: .utf8) {
                                try KeychainManager.shared.storeSSHKey(for: newServer.id, privateKey: keyData, passphrase: sshPassphrase.isEmpty ? nil : sshPassphrase, publicKey: publicKeyData)
                            }
                        }
                    }

                    if transportSelection == .cloudflare, selectedCloudflareAccessMode == .serviceToken {
                        try KeychainManager.shared.storeCloudflareServiceToken(
                            for: newServer.id,
                            clientID: cloudflareClientID,
                            clientSecret: cloudflareClientSecret
                        )
                    } else {
                        KeychainManager.shared.deleteCloudflareServiceToken(for: newServer.id)
                    }
                } else {
                    try await serverManager.addServer(newServer, credentials: credentials)
                }

                await MainActor.run {
                    isSaving = false
                    onSave(newServer)
                    dismiss()
                }
            } catch let error as VVTermError {
                await MainActor.run {
                    if case .proRequired = error {
                        self.showingServerLimitAlert = true
                    } else {
                        self.error = error.localizedDescription
                    }
                    self.isSaving = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isSaving = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ServerFormSheet(
        serverManager: ServerManager.shared,
        workspace: nil,
        onSave: { _ in }
    )
}
