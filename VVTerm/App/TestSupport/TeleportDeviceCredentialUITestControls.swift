#if DEBUG
import Foundation
import SwiftUI
import TeleportKit

/// Uses the production controls without starting authentication.
@MainActor
struct TeleportDeviceCredentialUITestControls: View {
    enum Content { case device, signIn }
    private let service: TeleportAccessService
    private let content: Content
    @StateObject private var model: TeleportProfileModel
    @State private var password = ""
    @State private var isSigningIn = false

    init(signedIn: Bool = false, content: Content = .device) {
        self.content = content
        let service = TeleportAccessService(
            keychain: KeychainStore(service: "test.teleport.credential.ui", backing: UnusedKeychain()),
            makeBrowserSession: { _, _ in preconditionFailure("This UI check must not open a browser") },
            didSignOut: { _ in }
        )
        self.service = service
        do {
            let profile = try TeleportProfileConfiguration(proxyURL: "https://proxy.example.invalid", account: "test-user")
            _model = StateObject(wrappedValue: TeleportProfileModel(
                profile: profile, service: service,
                summary: signedIn ? TeleportAccessSummary(
                    account: profile.account, clusterName: "test-cluster",
                    validBefore: .distantFuture, allowedLogins: ["test-login"]
                ) : nil,
                discovery: TeleportDiscovery(
                    clusterName: "test-cluster", serverVersion: "18.11.4",
                    authenticationType: "local", secondFactor: "otp", connectors: [],
                    webAuthnConfigured: content == .signIn
                ),
                credentialResult: signedIn ? .codeRequired : nil
            ))
        } catch {
            preconditionFailure("Invalid fixed Teleport UI profile")
        }
    }

    var body: some View {
        switch content {
        case .device:
            TeleportDeviceCredentialControls(
                service: service, model: model, password: $password,
                isSigningIn: $isSigningIn, onSignIn: {}
            )
        case .signIn:
            TeleportProfileSection(
                model: model, service: service, clusterName: .constant(""),
                nodeID: .constant(""), login: .constant(""), onSelectNode: { _ in }
            )
        }
    }

    private nonisolated enum Failure: Error { case unexpectedStorageAccess }

    private nonisolated struct UnusedKeychain: KeychainStoreBacking {
        func set(_ data: Data, service: String, key: String, scope: KeychainStorageScope) throws {
            throw Failure.unexpectedStorageAccess
        }
        func get(service: String, key: String, scope: KeychainStorageScope) throws -> Data? {
            throw Failure.unexpectedStorageAccess
        }
        func contains(service: String, key: String, scope: KeychainStorageScope) throws -> Bool {
            throw Failure.unexpectedStorageAccess
        }
        func delete(service: String, key: String, scope: KeychainStorageScope) throws {
            throw Failure.unexpectedStorageAccess
        }
        func keys(service: String, scope: KeychainStorageScope) throws -> [String] {
            throw Failure.unexpectedStorageAccess
        }
    }
}

@MainActor
struct TeleportCredentialSetupFormUITestFixture: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    private var testsSignIn: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-teleport-sign-in")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("vvterm.teleport.setupTest.draftName")
                }
                TeleportDeviceCredentialUITestControls(
                    signedIn: !testsSignIn, content: testsSignIn ? .signIn : .device
                )
            }
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif
