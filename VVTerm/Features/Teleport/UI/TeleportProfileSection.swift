import SwiftUI
import TeleportKit

struct TeleportProfileSection: View {
    let profile: TeleportProfileConfiguration
    let service: TeleportAccessService
    let onSelectNode: (TeleportNodeSelection) -> Void

    var body: some View {
        TeleportProfileContent(profile: profile, service: service, onSelectNode: onSelectNode)
            .id(profile)
    }
}

/// A changed profile has a new view identity and a new task owner.
private struct TeleportProfileContent: View {
    let profile: TeleportProfileConfiguration
    let onSelectNode: (TeleportNodeSelection) -> Void
    private let service: TeleportAccessService
    @StateObject private var model: TeleportProfileModel
    @State private var password = ""
    @State private var otp = ""
    @State private var selectedNodeID = ""
    @State private var selectedLogin = ""
    @State private var showingSignOutConfirmation = false

    init(
        profile: TeleportProfileConfiguration,
        service: TeleportAccessService,
        onSelectNode: @escaping (TeleportNodeSelection) -> Void
    ) {
        self.profile = profile
        self.service = service
        self.onSelectNode = onSelectNode
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
            if !logins.contains(selectedLogin) { selectedLogin = logins.first ?? "" }
        }
        .onChange(of: model.nodePage?.nodes.map(\.id) ?? []) { ids in
            if !ids.contains(selectedNodeID) { selectedNodeID = "" }
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
            }
            ForEach(model.connectors, id: \.profileButtonID) { connector in
                TeleportBrowserSignInButton(connector: connector, service: service, model: model) {
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
            } else {
                Picker("Node", selection: $selectedNodeID) {
                    Text("Select a node").tag("")
                    ForEach(page.nodes, id: \.id) { node in
                        Text("\(node.name) (\(node.id))").tag(node.id)
                    }
                }
                .disabled(model.isBusy)
                Picker("OS login", selection: $selectedLogin) {
                    if summary.allowedLogins.isEmpty {
                        Text("No permitted login").tag("")
                    }
                    ForEach(summary.allowedLogins, id: \.self) { login in
                        Text(login).tag(login)
                    }
                }
                .disabled(model.isBusy)
                Button("Use selected node") {
                    guard let node = page.nodes.first(where: { $0.id == selectedNodeID }),
                          summary.allowedLogins.contains(selectedLogin),
                          summary.validBefore > Date() else { return }
                    onSelectNode(TeleportNodeSelection(
                        clusterName: node.clusterName, nodeID: node.id, login: selectedLogin
                    ))
                }
                .disabled(model.isBusy || selectedNodeID.isEmpty || selectedLogin.isEmpty || summary.validBefore <= Date())
            }
            if page.hasMore {
                Button("More nodes") { model.loadNodes(startKey: page.nextKey) }
                    .disabled(model.isBusy)
            }
        }
        Button("Refresh nodes") { model.loadNodes() }
            .disabled(model.isBusy || summary.validBefore <= Date())
    }

    private var progressLabel: LocalizedStringKey {
        switch model.operation {
        case .idle: ""
        case .loading: "Checking access…"
        case .passwordLogin, .browserLogin: "Signing in…"
        case .loadingNodes: "Loading nodes…"
        case .signingOut: "Signing out…"
        }
    }
}

private extension TeleportConnector {
    var profileButtonID: String { kind.rawValue + ":" + id }
}
