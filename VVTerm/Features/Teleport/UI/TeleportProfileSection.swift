import Combine
import SwiftUI
import TeleportKit

struct TeleportProfileSection: View {
    let model: TeleportProfileModel
    let service: TeleportAccessService
    @Binding var password: String
    @Binding var clusterName: String
    @Binding var nodeID: String
    @Binding var login: String
    let onSelectNode: (String) -> Void
    var showsServerSelection = true

    var body: some View {
        TeleportProfileContent(
            model: model, service: service, password: $password, clusterName: $clusterName,
            nodeID: $nodeID, login: $login, onSelectNode: onSelectNode,
            showsServerSelection: showsServerSelection
        )
        .id(model.profile)
    }
}

/// Profile changes clear the sign-in fields. The server form owns authentication tasks.
private struct TeleportProfileContent: View {
    let onSelectNode: (String) -> Void
    private let service: TeleportAccessService
    private let showsServerSelection: Bool
    @Binding private var password: String
    @Binding private var clusterName: String
    @Binding private var nodeID: String
    @Binding private var login: String
    @ObservedObject private var model: TeleportProfileModel
    private enum SignInMethod: Hashable { case code, browser, device }
    @State private var selectedMethod: SignInMethod?
    @State private var otp = ""
    @State private var hasReadNodePage = false
    @State private var showingSignOutConfirmation = false

    init(
        model: TeleportProfileModel,
        service: TeleportAccessService,
        password: Binding<String>,
        clusterName: Binding<String>,
        nodeID: Binding<String>,
        login: Binding<String>,
        onSelectNode: @escaping (String) -> Void,
        showsServerSelection: Bool
    ) {
        self.service = service
        self.showsServerSelection = showsServerSelection
        self.onSelectNode = onSelectNode
        _password = password
        _clusterName = clusterName
        _nodeID = nodeID
        _login = login
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            if model.discovery == nil {
                Section {
                    Button("Continue") { model.load() }
                        .accessibilityIdentifier("vvterm.teleport.continue")
                        .disabled(model.isBusy)
                    operationFeedback
                } header: {
                    Text("Teleport")
                }
            } else if showsSignIn {
                Section {
                    loginControls
                    operationFeedback
                } header: {
                    Text("Sign in")
                }
            }
            if showsServerSelection, let summary = validSummary {
                serverSection(summary: summary)
            }
        }
        .onReceive(model.$summary.dropFirst()) { _ in
            selectedMethod = nil
        }
        .onChange(of: selectedMethod) { _ in otp = "" }
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

    private var validSummary: TeleportAccessSummary? {
        guard let summary = model.summary, summary.validBefore > Date() else { return nil }
        return summary
    }

    private var showsSignIn: Bool {
        !showsServerSelection || selectedMethod != nil || validSummary == nil
    }

    private func serverSection(summary: TeleportAccessSummary) -> some View {
        Section {
            nodeControls(summary: summary)
            LabeledContent("Access expires") {
                Text(summary.validBefore, format: .dateTime.month(.abbreviated).day().hour().minute())
            }
            Menu("Manage access") {
                Button("Refresh servers") {
                    hasReadNodePage = false
                    model.loadNodes()
                }
                Button("Sign in again") { selectedMethod = .code }
                Button("Sign out", role: .destructive) { showingSignOutConfirmation = true }
            }
            .disabled(model.isBusy)
            if model.discovery != nil && !showsSignIn {
                operationFeedback
            }
        } header: {
            Text("Server")
        }
        .confirmationDialog("Sign out?", isPresented: $showingSignOutConfirmation) {
            Button("Sign out", role: .destructive) {
                otp = ""
                selectedMethod = nil
                model.signOut()
            }
        } message: {
            Text("This closes this account's sessions on this device. The saved password stays.")
        }
    }

    @ViewBuilder
    private var operationFeedback: some View {
        if let failure = model.failure, !failure.operation.isCredentialManagement {
            Text(failure.message)
                .foregroundStyle(.red)
        }
        if model.isBusy && !model.operation.isCredentialManagement {
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
    }

    @ViewBuilder
    private var loginControls: some View {
        if let discovery = model.discovery {
            if discovery.authenticationType == "local" {
                if discovery.webAuthnConfigured {
                    Picker("Verify with", selection: Binding(
                        get: { selectedMethod ?? .code },
                        set: { selectedMethod = $0 }
                    )) {
                        Text(discovery.secondFactor == "off" ? "Password" : "Authenticator code").tag(SignInMethod.code)
                        Text("Passkey or security key").tag(SignInMethod.browser)
                        Text("This device").tag(SignInMethod.device)
                    }
                    .accessibilityIdentifier("vvterm.teleport.signInMethod")
                    .disabled(model.isBusy)
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("vvterm.teleport.password")
                    .disabled(model.isBusy)
                if selectedMethod == .browser && discovery.webAuthnConfigured {
                    TeleportBrowserSignInButton(
                        method: .localMFA(password: password), service: service, model: model,
                        onStart: { otp = "" }
                    )
                    .disabled(model.isBusy || password.isEmpty)
                } else if selectedMethod == .device && discovery.webAuthnConfigured {
                    Text("Approve with Face ID or Touch ID.").foregroundStyle(.secondary)
                    Button("Sign in") {
                        model.loginWithSecureEnclave(password: password)
                        otp = ""
                    }
                    .accessibilityIdentifier("vvterm.teleport.signIn")
                    .disabled(model.isBusy || password.isEmpty)
                } else {
                    if discovery.secondFactor != "off" {
                        SecureField("Authenticator code", text: $otp)
                            .accessibilityIdentifier("vvterm.teleport.otp")
                            .disabled(model.isBusy)
                    }
                    Button("Sign in") {
                        model.login(password: password, otp: otp)
                        otp = ""
                    }
                    .accessibilityIdentifier("vvterm.teleport.signIn")
                    .disabled(model.isBusy || password.isEmpty)
                }
            }
            ForEach(model.connectors, id: \.profileButtonID) { connector in
                TeleportBrowserSignInButton(
                    method: .sso(connector), service: service, model: model,
                    onStart: { otp = "" }
                )
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
                Text("No servers on this page.")
                    .foregroundStyle(.secondary)
            }
            if !page.nodes.isEmpty || !nodeID.isEmpty {
                Picker("Server", selection: Binding(
                    get: { nodeID },
                    set: { id in
                        if let node = page.nodes.first(where: { $0.id == id }) {
                            selectNode(node)
                        }
                    }
                )) {
                    if nodeID.isEmpty {
                        Text("Choose a server").tag("")
                    } else if !page.nodes.contains(where: { $0.id == nodeID }) {
                        Text("Current server (not on this page)").tag(nodeID)
                    }
                    ForEach(page.nodes, id: \.id) { node in
                        Text(nodeLabel(node, in: page.nodes)).tag(node.id)
                    }
                }
                .accessibilityIdentifier("vvterm.teleport.node")
                .disabled(model.isBusy || summary.validBefore <= Date())
                Picker("SSH login", selection: $login) {
                    if login.isEmpty {
                        Text(summary.allowedLogins.isEmpty ? "No permitted login" : "Choose a login").tag("")
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
                Button("More servers") { model.loadNodes(startKey: page.nextKey) }
                    .disabled(model.isBusy)
            }
        }
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
