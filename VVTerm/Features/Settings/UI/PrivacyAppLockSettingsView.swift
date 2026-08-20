import SwiftUI

struct PrivacyAppLockSettingsView: View {
    let analyticsOptOutAction: AnalyticsOptOutAction

    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false
    @AppStorage(AnalyticsTracker.enabledKey) private var analyticsEnabled = true
    @EnvironmentObject private var appLockManager: AppLockManager

    private let authGraceOptions = [0, 15, 30, 60, 120, 300]

    var body: some View {
        Form {
            Section {
                Toggle("Privacy Mode", isOn: $privacyModeEnabled)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Privacy mode hides server addresses and usernames in the app UI and when the app is inactive.")
            }

            Section {
                Toggle(
                    "Help Improve VVTerm",
                    isOn: Binding(
                        get: { analyticsEnabled },
                        set: { newValue in
                            analyticsOptOutAction.applyTransition(
                                from: analyticsEnabled,
                                to: newValue
                            ) { analyticsEnabled = $0 }
                        }
                    )
                )
            } header: {
                Text("Analytics")
            } footer: {
                Text("Help Improve VVTerm shares anonymous statistics about which features are used — never what you type, your servers, or anything that identifies you.")
            }

            Section {
                Toggle(
                    String(
                        format: String(localized: "Require %@ to open VVTerm"),
                        appLockManager.biometryDisplayName
                    ),
                    isOn: Binding(
                        get: { appLockManager.fullAppLockEnabled },
                        set: { newValue in
                            Task {
                                await appLockManager.requestSetFullAppLockEnabled(newValue)
                            }
                        }
                    )
                )
                .disabled(
                    appLockManager.isAuthenticating
                        || (!appLockManager.isBiometryAvailable && !appLockManager.fullAppLockEnabled)
                )

                if appLockManager.fullAppLockEnabled {
                    Toggle("Lock when app goes to background", isOn: $appLockManager.lockOnBackground)

                    Picker("Re-auth grace period", selection: $appLockManager.authGraceSeconds) {
                        ForEach(authGraceOptions, id: \.self) { seconds in
                            if seconds == 0 {
                                Text("Always").tag(seconds)
                            } else {
                                Text(String(format: String(localized: "%lld seconds"), Int64(seconds)))
                                    .tag(seconds)
                            }
                        }
                    }
                }

                if let message = appLockManager.biometryAvailabilityMessage,
                   !appLockManager.isBiometryAvailable {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = appLockManager.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("App Lock")
            } footer: {
                Text("Biometric lock protects app and server access on this device.")
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.privacyAndAppLock")
        .onAppear {
            appLockManager.refreshBiometryAvailability()
        }
    }
}
