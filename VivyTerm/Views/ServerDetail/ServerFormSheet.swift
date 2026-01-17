import SwiftUI
#if os(iOS)
import UIKit
#endif

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

    @State private var showingServerLimitAlert = false
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
            username: effectiveUsername,
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
            TextField("Name", text: $name)
                #if os(iOS)
                .textContentType(.name)
                #endif

            HStack(spacing: 12) {
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
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76)
            }

            TextField("Username", text: $username, prompt: Text("root"))
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

            case .sshKeyWithPassphrase:
                keyInputView
                SecureField("Key Passphrase", text: $sshPassphrase)
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
            username: effectiveUsername,
            authMethod: authMethod,
            notes: notes.isEmpty ? nil : notes,
            tmuxEnabledOverride: tmuxEnabled,
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
                    isSaving = false
                    onSave(newServer)
                    dismiss()
                }
            } catch let error as VivyTermError {
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
