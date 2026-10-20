#if DEBUG
import SwiftUI
import TeleportKit

/// Renders the production recovery controls without starting authentication.
@MainActor
struct TeleportDeviceCredentialUITestControls: View {
    private let service: TeleportAccessService
    @StateObject private var model: TeleportProfileModel

    init(signedIn: Bool = false) {
        let service = TeleportAccessService(
            keychain: KeychainStore(service: "test.teleport.credential.ui", backing: UnusedKeychain()),
            makeBrowserSession: { _, _ in preconditionFailure("This UI check must not open a browser") },
            didSignOut: { _ in }
        )
        self.service = service
        do {
            let profile = try TeleportProfileConfiguration(proxyURL: "https://proxy.example.invalid", account: "test-user")
            if signedIn {
                _model = StateObject(wrappedValue: TeleportProfileModel(
                    profile: profile, service: service,
                    summary: TeleportAccessSummary(
                        account: profile.account, clusterName: "test-cluster",
                        validBefore: .distantFuture, allowedLogins: ["test-login"]
                    ),
                    discovery: TeleportDiscovery(
                        clusterName: "test-cluster", serverVersion: "18.11.4",
                        authenticationType: "local", secondFactor: "otp", connectors: []
                    )
                ))
            } else {
                _model = StateObject(wrappedValue: TeleportProfileModel(profile: profile, service: service))
            }
        } catch {
            preconditionFailure("Invalid fixed Teleport UI profile")
        }
    }

    var body: some View {
        TeleportDeviceCredentialControls(service: service, model: model)
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("vvterm.teleport.setupTest.draftName")
                    TeleportDeviceCredentialUITestControls(signedIn: true)
                }
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
