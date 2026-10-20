import SwiftUI
import TeleportKit

struct TeleportProfileSection: View {
    let profile: TeleportProfileConfiguration
    let service: TeleportAccessService
    @Binding var clusterName: String
    @Binding var nodeID: String
    @Binding var login: String
    let onSelectNode: (String) -> Void

    var body: some View {
        TeleportProfileContent(
            profile: profile, service: service, clusterName: $clusterName,
            nodeID: $nodeID, login: $login, onSelectNode: onSelectNode
        )
        .id(profile)
    }
}

/// A changed profile has a new view identity and a new task owner.
private struct TeleportProfileContent: View {
    let profile: TeleportProfileConfiguration
    let onSelectNode: (String) -> Void
    private let service: TeleportAccessService
    @Binding private var clusterName: String
    @Binding private var nodeID: String
    @Binding private var login: String
    @StateObject private var model: TeleportProfileModel
    @State private var password = ""
    @State private var otp = ""
    @State private var hasReadNodePage = false
    @State private var showingSignOutConfirmation = false

    init(
        profile: TeleportProfileConfiguration,
        service: TeleportAccessService,
        clusterName: Binding<String>,
        nodeID: Binding<String>,
        login: Binding<String>,
        onSelectNode: @escaping (String) -> Void
    ) {
        self.profile = profile
        self.service = service
        self.onSelectNode = onSelectNode
        _clusterName = clusterName
        _nodeID = nodeID
        _login = login
        _model = StateObject(wrappedValue: TeleportProfileModel(profile: profile, service: service))
    }

    var body: some View {
        Section {
            LabeledContent("Account", value: profile.account)
            if let summary = model.summary {
                LabeledContent("Cluster", value: summary.clusterName)
                LabeledContent("Access expires") {
                    Text(summary.validBefore, format: .dateTime)
                }
                if summary.validBefore <= Date() {
                    Text("Sign in again to renew access.")
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Sign in again") { loginControls }
                nodeControls(summary: summary)
                Button("Sign out", role: .destructive) { showingSignOutConfirmation = true }
                    .disabled(model.isBusy)
            } else {
                loginControls
            }
            TeleportDeviceCredentialControls(service: service, model: model)
            if let result = model.credentialResult {
                switch result {
                case .registered:
                    Text("Device credential registered. Use your password and Face ID or Touch ID to sign in.")
                case .deleted:
                    Text("Local device credential removed. Remove its server entry in Teleport separately.")
                }
            }
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
            if model.isBusy {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.operation != .signingOut {
                        Button("Cancel") { model.cancel() }
                    }
                }
            }
            Button("Check access") { model.load() }
                .disabled(model.isBusy)
        } header: {
            Text("Teleport access")
        } footer: {
            Text("Issued access is stored only on this device. Passwords and one-time codes are not saved.")
        }
        .confirmationDialog("Sign out of Teleport?", isPresented: $showingSignOutConfirmation) {
            Button("Sign out", role: .destructive) {
                password = ""
                otp = ""
                model.signOut()
            }
        } message: {
            Text("This disconnects all sessions for this Teleport profile on this device.")
        }
        .onAppear { model.load() }
        .onDisappear {
            model.cancel()
            password = ""
            otp = ""
        }
        .onChange(of: model.summary?.allowedLogins ?? []) { logins in
            if login.isEmpty, logins.count == 1 { login = logins[0] }
        }
        .onChange(of: model.operation) { operation in
            switch operation {
            case .loading, .passwordLogin, .browserLogin, .biometricLogin:
                hasReadNodePage = false
            default:
                break
            }
        }
        .onChange(of: model.nodePage) { page in
            guard let page else { return }
            defer { hasReadNodePage = true }
            // A final page alone does not mean that the cluster has only one node.
            if let node = TeleportProfileModel.singleNode(
                in: page.nodes, hasMore: page.hasMore, currentNodeID: nodeID, isFirstPage: !hasReadNodePage
            ) {
                selectNode(node)
            }
        }
    }

    @ViewBuilder
    private var loginControls: some View {
        if let discovery = model.discovery {
            if discovery.authenticationType == "local" {
                SecureField("Password", text: $password)
                    .disabled(model.isBusy)
                SecureField("One-time code (if needed)", text: $otp)
                    .disabled(model.isBusy)
                Button("Sign in") {
                    model.login(password: password, otp: otp)
                    password = ""
                    otp = ""
                }
                .disabled(model.isBusy || password.isEmpty)
                DisclosureGroup("Other sign-in options") {
                    Button("Sign in with Face ID or Touch ID") {
                        model.loginWithSecureEnclave(password: password)
                        password = ""
                        otp = ""
                    }
                    .disabled(model.isBusy || password.isEmpty)
                    Text("Set up this device after your first sign-in.")
                        .foregroundStyle(.secondary)
                    if discovery.webAuthnConfigured {
                        TeleportBrowserSignInButton(
                            method: .localMFA(password: password), service: service, model: model
                        ) {
                            password = ""
                            otp = ""
                        }
                        .disabled(model.isBusy || password.isEmpty)
                    }
                }
            }
            ForEach(model.connectors, id: \.profileButtonID) { connector in
                TeleportBrowserSignInButton(method: .sso(connector), service: service, model: model) {
                    password = ""
                    otp = ""
                }
                .disabled(model.isBusy)
            }
            if discovery.authenticationType != "local" && model.connectors.isEmpty {
                Text("No supported sign-in method is available for this profile.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func nodeControls(summary: TeleportAccessSummary) -> some View {
        if let page = model.nodePage {
            if page.nodes.isEmpty {
                Text("No nodes are available in this page.")
                    .foregroundStyle(.secondary)
            }
            if !page.nodes.isEmpty || !nodeID.isEmpty {
                Picker("Node", selection: Binding(
                    get: { nodeID },
                    set: { id in
                        if let node = page.nodes.first(where: { $0.id == id }) {
                            selectNode(node)
                        }
                    }
                )) {
                    if nodeID.isEmpty {
                        Text("Select a node").tag("")
                    } else if !page.nodes.contains(where: { $0.id == nodeID }) {
                        Text("Current node (not in this page)").tag(nodeID)
                    }
                    ForEach(page.nodes, id: \.id) { node in
                        Text(nodeLabel(node, in: page.nodes)).tag(node.id)
                    }
                }
                .accessibilityIdentifier("vvterm.teleport.node")
                .disabled(model.isBusy || summary.validBefore <= Date())
                Picker("OS login", selection: $login) {
                    if login.isEmpty {
                        Text(summary.allowedLogins.isEmpty ? "No permitted login" : "Select an OS login").tag("")
                    } else if !summary.allowedLogins.contains(login) {
                        Text("\(login) (not permitted)").tag(login)
                    }
                    ForEach(summary.allowedLogins, id: \.self) { login in
                        Text(login).tag(login)
                    }
                }
                .accessibilityIdentifier("vvterm.teleport.login")
                .disabled(model.isBusy || summary.validBefore <= Date())
            }
            if page.hasMore {
                Button("More nodes") { model.loadNodes(startKey: page.nextKey) }
                    .disabled(model.isBusy)
            }
        }
        Button("Refresh nodes") {
            hasReadNodePage = false
            model.loadNodes()
        }
            .disabled(model.isBusy || summary.validBefore <= Date())
    }

    private func selectNode(_ node: TeleportNode) {
        clusterName = node.clusterName
        nodeID = node.id
        onSelectNode(node.name)
    }

    private func nodeLabel(_ node: TeleportNode, in nodes: [TeleportNode]) -> String {
        nodes.contains { $0.name == node.name && $0.id != node.id }
            ? "\(node.name) (\(node.id))" : node.name
    }

    private var progressLabel: LocalizedStringKey {
        switch model.operation {
        case .idle: ""
        case .loading: "Checking access…"
        case .passwordLogin, .browserLogin, .biometricLogin: "Signing in…"
        case .registeringCredential: "Setting up device credential…"
        case .deletingCredential: "Removing local credential…"
        case .loadingNodes: "Loading nodes…"
        case .signingOut: "Signing out…"
        }
    }
}

private extension TeleportConnector {
    var profileButtonID: String { kind.rawValue + ":" + id }
}
