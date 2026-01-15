import SwiftUI
import UniformTypeIdentifiers

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
    @State private var authMethod: AuthMethod = .password
    @State private var password: String = ""
    @State private var sshKey: String = ""
    @State private var sshPassphrase: String = ""
    @State private var selectedEnvironment: ServerEnvironment = .production
    @State private var notes: String = ""
    @State private var tmuxEnabled: Bool = true

    @State private var showingKeyImporter = false
    @State private var showingProUpgrade = false
    @State private var showingAddKeySheet = false
    @State private var isSaving = false
    @State private var isLoadingCredentials = false
    @State private var error: String?
    @State private var storedKeys: [SSHKeyEntry] = []
    @State private var selectedStoredKey: SSHKeyEntry?
    @State private var isTestingConnection = false
    @State private var connectionTestError: String?
    @State private var connectionTestSucceeded = false
    @State private var lastTestSnapshot: ConnectionTestSnapshot?
    @State private var initialConnectionSnapshot: ConnectionTestSnapshot?

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
            _authMethod = State(initialValue: server.authMethod)
            _selectedEnvironment = State(initialValue: server.environment)
            _notes = State(initialValue: server.notes ?? "")
            _tmuxEnabled = State(initialValue: server.tmuxEnabledOverride ?? Self.defaultTmuxEnabled())
        } else {
            _tmuxEnabled = State(initialValue: Self.defaultTmuxEnabled())
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
        let authMethod: AuthMethod
        let password: String
        let sshKey: String
        let sshPassphrase: String
    }

    private var connectionSnapshot: ConnectionTestSnapshot {
        ConnectionTestSnapshot(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            password: password,
            sshKey: sshKey,
            sshPassphrase: sshPassphrase
        )
    }

    private var shouldRequireConnectionTest: Bool {
        guard isValid else { return false }
        guard isEditing else { return true }
        if let initialConnectionSnapshot {
            return initialConnectionSnapshot != connectionSnapshot
        }
        return true
    }

    private var hasValidConnectionTest: Bool {
        connectionTestSucceeded && lastTestSnapshot == connectionSnapshot
    }

    var body: some View {
        NavigationStack {
            Form {
                // Limit Banner (only for new servers, non-Pro users at limit)
                if isAtLimit {
                    Section {
                        ProLimitBanner(
                            title: String(localized: "Server Limit Reached"),
                            message: String(format: String(localized: "You've reached the limit of %lld servers. Upgrade to Pro for unlimited servers."), Int64(FreeTierLimits.maxServers))
                        ) {
                            showingProUpgrade = true
                        }
                    }
                } else if !isEditing && !storeManager.isPro {
                    // Show usage indicator when approaching limit
                    Section {
                        UsageIndicator(
                            current: serverCount,
                            limit: FreeTierLimits.maxServers,
                            label: String(localized: "Servers"),
                            showUpgrade: $showingProUpgrade
                        )
                    }
                }

                // Basic Info
                Section("Server Info") {
                    TextField("Name", text: $name)
                        #if os(iOS)
                        .textContentType(.name)
                        #endif

                    TextField("Host", text: $host)
                        #if os(iOS)
                        .textContentType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif

                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif

                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textContentType(.username)
                        #endif
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                // Authentication
                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Label(method.displayName, systemImage: method.icon)
                                .tag(method)
                        }
                    }

                    switch authMethod {
                    case .password:
                        SecureField("Password", text: $password)
                            #if os(iOS)
                            .textContentType(.password)
                            #endif

                    case .sshKey:
                        keyInputView
                        if !sshKey.isEmpty {
                            Text("Key loaded")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                    case .sshKeyWithPassphrase:
                        keyInputView
                        if !sshKey.isEmpty {
                            Text("Key loaded")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        SecureField("Key Passphrase", text: $sshPassphrase)
                    }
                }

                // Connection Test
                Section("Connection") {
                    Button {
                        Task {
                            await runConnectionTest(force: true)
                        }
                    } label: {
                        if isTestingConnection {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text(String(localized: "Testing connection..."))
                            }
                        } else {
                            Text(String(localized: "Test Connection"))
                        }
                    }
                    .disabled(!isValid || isTestingConnection)

                    if connectionTestSucceeded && hasValidConnectionTest {
                        Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if let connectionTestError {
                        Text(connectionTestError)
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else if shouldRequireConnectionTest {
                        Text(String(localized: "Connection will be verified before saving."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Session Persistence") {
                    Toggle("Use tmux to preserve sessions", isOn: $tmuxEnabled)
                    Text("Sessions stay alive across app restarts and disconnects when tmux is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Environment
                Section("Server Environment") {
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
                }

                // Notes
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }

                // Error
                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? String(localized: "Edit Server") : String(localized: "Add Server"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                // Load credentials from keychain when editing
                guard let server = server else { return }
                isLoadingCredentials = true
                defer { isLoadingCredentials = false }

                do {
                    let credentials = try KeychainManager.shared.getCredentials(for: server)

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
                } catch {
                    self.error = String(format: String(localized: "Failed to load credentials: %@"), error.localizedDescription)
                }

                if initialConnectionSnapshot == nil {
                    initialConnectionSnapshot = connectionSnapshot
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "Save") : String(localized: "Add")) {
                        saveServer()
                    }
                    .disabled(!isValid || isSaving || isAtLimit || isLoadingCredentials || isTestingConnection)
                }
            }
            .sheet(isPresented: $showingProUpgrade) {
                ProUpgradeSheet()
            }
            .fileImporter(
                isPresented: $showingKeyImporter,
                allowedContentTypes: [.data, .text],
                allowsMultipleSelection: false
            ) { result in
                handleKeyImport(result)
            }
            .sheet(isPresented: $showingAddKeySheet) {
                AddSSHKeySheet(onSave: { entry in
                    storedKeys = KeychainManager.shared.getStoredSSHKeys()
                    selectedStoredKey = entry
                    loadStoredKey(entry)
                })
            }
            .onAppear {
                storedKeys = KeychainManager.shared.getStoredSSHKeys()
                if !isEditing && initialConnectionSnapshot == nil {
                    initialConnectionSnapshot = connectionSnapshot
                }
            }
            .onChange(of: host) { _ in resetConnectionTestState() }
            .onChange(of: port) { _ in resetConnectionTestState() }
            .onChange(of: username) { _ in resetConnectionTestState() }
            .onChange(of: authMethod) { _ in resetConnectionTestState() }
            .onChange(of: password) { _ in resetConnectionTestState() }
            .onChange(of: sshKey) { _ in resetConnectionTestState() }
            .onChange(of: sshPassphrase) { _ in resetConnectionTestState() }
        }
    }

    // MARK: - Key Input View

    @ViewBuilder
    private var keyInputView: some View {
        // Stored keys picker
        if !storedKeys.isEmpty {
            Picker("Use Stored Key", selection: $selectedStoredKey) {
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

        // Manual key input options
        HStack {
            Button("Import File") {
                showingKeyImporter = true
            }

            Button("Paste") {
                #if os(iOS)
                if let key = UIPasteboard.general.string {
                    sshKey = key
                    selectedStoredKey = nil
                }
                #elseif os(macOS)
                if let key = NSPasteboard.general.string(forType: .string) {
                    sshKey = key
                    selectedStoredKey = nil
                }
                #endif
            }

            Spacer()

            Button("Add to Keychain") {
                showingAddKeySheet = true
            }
            .font(.caption)
        }

        if sshKey.isEmpty && selectedStoredKey == nil {
            Text("Select a stored key or import/paste a new one")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if selectedStoredKey != nil {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(format: String(localized: "Using stored key: %@"), selectedStoredKey!.name))
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func loadStoredKey(_ entry: SSHKeyEntry) {
        do {
            if let keyData = try KeychainManager.shared.getStoredSSHKeyData(for: entry.id) {
                if let keyString = String(data: keyData.key, encoding: .utf8) {
                    sshKey = keyString
                }
                if let passphrase = keyData.passphrase {
                    sshPassphrase = passphrase
                }
            }
        } catch {
            self.error = String(format: String(localized: "Failed to load key: %@"), error.localizedDescription)
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !name.isEmpty &&
        !host.isEmpty &&
        !username.isEmpty &&
        Int(port) != nil &&
        hasValidCredentials
    }

    private var hasValidCredentials: Bool {
        switch authMethod {
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
            username: username,
            authMethod: authMethod,
            notes: notes.isEmpty ? nil : notes,
            tmuxEnabledOverride: tmuxEnabled,
            createdAt: createdAt
        )
    }

    private static func defaultTmuxEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "terminalTmuxEnabledDefault") == nil {
            return true
        }
        return defaults.bool(forKey: "terminalTmuxEnabledDefault")
    }

    private func buildCredentials(for serverId: UUID) -> ServerCredentials {
        var credentials = ServerCredentials(serverId: serverId)
        switch authMethod {
        case .password:
            credentials.password = password
        case .sshKey:
            credentials.sshKey = sshKey.data(using: .utf8)
        case .sshKeyWithPassphrase:
            credentials.sshKey = sshKey.data(using: .utf8)
            credentials.sshPassphrase = sshPassphrase
        }
        return credentials
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
                connectionTestError = error.localizedDescription
                connectionTestSucceeded = false
                success = false
            }
        }

        return success
    }

    // MARK: - Actions

    private func handleKeyImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let keyContent = try String(contentsOf: url, encoding: .utf8)
                sshKey = keyContent
            } catch {
                self.error = String(format: String(localized: "Failed to read key file: %@"), error.localizedDescription)
            }
        case .failure(let error):
            self.error = String(format: String(localized: "Failed to import key: %@"), error.localizedDescription)
        }
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

                let needsConnectionTest = await MainActor.run { shouldRequireConnectionTest && !hasValidConnectionTest }
                if needsConnectionTest {
                    let success = await runConnectionTest(force: false)
                    guard success else {
                        await MainActor.run {
                            error = connectionTestError ?? String(localized: "Connection test failed")
                            isSaving = false
                        }
                        return
                    }
                }

                if isEditing {
                    try await serverManager.updateServer(newServer)
                    // Store credentials based on auth method
                    switch authMethod {
                    case .password:
                        if !password.isEmpty {
                            try KeychainManager.shared.storePassword(for: newServer.id, password: password)
                        }
                    case .sshKey:
                        if !sshKey.isEmpty, let keyData = sshKey.data(using: .utf8) {
                            try KeychainManager.shared.storeSSHKey(for: newServer.id, privateKey: keyData, passphrase: nil)
                        }
                    case .sshKeyWithPassphrase:
                        if !sshKey.isEmpty, let keyData = sshKey.data(using: .utf8) {
                            try KeychainManager.shared.storeSSHKey(for: newServer.id, privateKey: keyData, passphrase: sshPassphrase.isEmpty ? nil : sshPassphrase)
                        }
                    }
                } else {
                    try await serverManager.addServer(newServer, credentials: credentials)
                }

                await MainActor.run {
                    onSave(newServer)
                    dismiss()
                }
            } catch let error as VivyTermError {
                await MainActor.run {
                    if case .proRequired = error {
                        self.showingProUpgrade = true
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
