import SwiftUI

struct SyncSettingsView: View {
    @EnvironmentObject private var coordinator: SyncSettingsCoordinator
    @State private var syncEnabled = SyncSettings.isEnabled
    @State private var ignoresNextSyncToggleChange = false
    @State private var isConfirmingCredentialRemoval = false

    var body: some View {
        Form {
            statusHeroSection
            syncToggleSection
            if let attentionMessage {
                troubleshootingSection(message: attentionMessage)
            }
            SyncSettingsDetailsSections(
                summary: coordinator.contentSummary,
                contentSyncState: contentSyncState,
                syncEnabled: syncEnabled,
                lastSuccessfulSyncDate: coordinator.lastSuccessfulSyncDate,
                pendingChangeCount: coordinator.cloudState.outstandingOperationCount,
                lastError: coordinator.lastError,
                diagnostics: coordinator.diagnostics.text,
                requestCredentialRemoval: {
                    isConfirmingCredentialRemoval = true
                }
            )
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.iCloudSync")
        .onAppear {
            coordinator.refreshSnapshots()
        }
        .onChange(of: syncEnabled, perform: handleSyncToggle)
        .onChange(of: coordinator.manualSyncState) { state in
            guard let message = state.announcement else { return }
            SyncSettingsAccessibilityAnnouncement.post(message)
        }
        .confirmationDialog(
            "Remove Credentials from iCloud Keychain?",
            isPresented: $isConfirmingCredentialRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove from iCloud Keychain", role: .destructive) {
                _ = coordinator.removeCredentialsFromICloud()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Credentials remain on this device. If you enable sync again, VVTerm will store them in iCloud Keychain again.")
        }
    }

    private var statusHeroSection: some View {
        Section {
            SyncSettingsStatusHero(
                state: coordinator.userState,
                lastSuccessfulSyncDate: coordinator.lastSuccessfulSyncDate,
                primaryAction: primaryAction,
                onPrimaryAction: handlePrimaryAction
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }

    private var syncToggleSection: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $syncEnabled)
                .accessibilityIdentifier("vvterm.settings.sync.toggle")
        }
    }

    private func troubleshootingSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vvterm.settings.sync.troubleshooting")
        }
    }

    private var contentSyncState: SyncSettingsContentSyncState {
        SyncSettingsContentSyncState(
            syncEnabled: syncEnabled,
            userState: coordinator.userState,
            lastSuccessfulSyncDate: coordinator.lastSuccessfulSyncDate
        )
    }

    private var primaryAction: SyncSettingsPrimaryAction? {
        guard syncEnabled else { return nil }
        if coordinator.manualSyncState == .running {
            return .syncing
        }
        if coordinator.canSyncNow {
            return attentionMessage == nil ? .syncNow : .tryAgain
        }
        return attentionMessage == nil ? nil : .checkAgain
    }

    private var attentionMessage: String? {
        credentialFailureText ?? coordinator.userState.recoveryGuidance
    }

    private var credentialFailureText: String? {
        switch coordinator.credentialFailure {
        case .toggle:
            String(localized: "Credentials could not be copied. Nothing was removed.")
        case .sync:
            String(localized: "Credentials and SSH keys need attention.")
        case .removal:
            String(
                localized: "VVTerm could not remove every item. Your local copies remain safe. Try again."
            )
        case nil:
            nil
        }
    }

    private func handlePrimaryAction() {
        if coordinator.canSyncNow {
            Task { await coordinator.syncNow() }
        } else {
            Task { await coordinator.checkICloudStatus() }
        }
    }

    private func handleSyncToggle(_ enabled: Bool) {
        if ignoresNextSyncToggleChange {
            ignoresNextSyncToggleChange = false
            return
        }
        guard coordinator.setSyncEnabled(enabled) else {
            ignoresNextSyncToggleChange = true
            syncEnabled = !enabled
            return
        }
        if enabled {
            Task { await coordinator.syncNow() }
        }
    }
}
