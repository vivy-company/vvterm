import SwiftUI

struct SyncSettingsDetailsSections: View {
    let summary: SyncSettingsContentSummary
    let contentSyncState: SyncSettingsContentSyncState
    let syncEnabled: Bool
    let lastSuccessfulSyncDate: Date?
    let pendingChangeCount: Int
    let lastError: SyncSettingsErrorRecord?
    let diagnostics: String
    let requestCredentialRemoval: () -> Void

    @State private var copiedDiagnostics: String?

    var body: some View {
        syncedDataSection
        syncDetailsSection
        if !syncEnabled {
            credentialRemovalSection
        }
    }

    private var syncedDataSection: some View {
        Section {
            SyncSettingsDetailsCountRow(
                title: "Servers",
                systemImage: "server.rack",
                count: summary.serverCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.servers"
            )
            SyncSettingsDetailsCountRow(
                title: "Workspaces",
                systemImage: "folder",
                count: summary.workspaceCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.workspaces"
            )
            SyncSettingsDetailsCountRow(
                title: "Server Credentials",
                systemImage: "key.fill",
                count: summary.serverCredentialCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.serverCredentials"
            )
            SyncSettingsDetailsCountRow(
                title: "Reusable SSH Keys",
                systemImage: "key.horizontal.fill",
                count: summary.reusableSSHKeyCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.reusableSSHKeys"
            )
            SyncSettingsDetailsCountRow(
                title: "Custom Themes",
                systemImage: "paintpalette",
                count: summary.customThemeCount,
                accessibilityIdentifier: "vvterm.settings.sync.details.customThemes"
            )
            SyncSettingsDetailsStatusRow(
                title: "Terminal Appearance",
                systemImage: "circle.lefthalf.filled",
                status: storageStatus
            )
            SyncSettingsDetailsStatusRow(
                title: "Keyboard Toolbar",
                systemImage: "keyboard",
                status: storageStatus
            )
            SyncSettingsDetailsStatusRow(
                title: "Stats Layout",
                systemImage: "chart.xyaxis.line",
                status: storageStatus
            )
            SyncSettingsDetailsStatusRow(
                title: "Cloudflare Tokens",
                systemImage: "lock.shield",
                status: storageStatus
            )
        } header: {
            Text(contentSyncState.sectionTitle)
        } footer: {
            if syncEnabled {
                Text("Passwords, private keys, passphrases, and Cloudflare tokens use iCloud Keychain.")
            }
        }
    }

    private var syncDetailsSection: some View {
        Section("Sync Details") {
            if let lastSuccessfulSyncDate {
                LabeledContent("Last Successful Sync") {
                    Text(
                        lastSuccessfulSyncDate,
                        format: .dateTime.year().month().day().hour().minute()
                    )
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("vvterm.settings.sync.details.lastSuccessful")
            }

            if pendingChangeCount > 0 {
                LabeledContent("Pending Changes") {
                    Text(pendingChangeCount, format: .number)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("vvterm.settings.sync.details.pendingChanges")
            }

            if let lastError {
                LabeledContent("Last Sync Error") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(lastError.category.title)
                        Text(
                            lastError.date,
                            format: .dateTime.year().month().day().hour().minute()
                        )
                        .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("vvterm.settings.sync.details.lastError")
            }

            Button {
                Clipboard.copy(diagnostics)
                copiedDiagnostics = diagnostics
                SyncSettingsAccessibilityAnnouncement.post(
                    String(localized: "Copied")
                )
            } label: {
                Label(
                    copiedDiagnostics == diagnostics
                        ? String(localized: "Copied")
                        : String(localized: "Copy Diagnostics"),
                    systemImage: copiedDiagnostics == diagnostics
                        ? "checkmark"
                        : "doc.on.doc"
                )
            }
            .accessibilityIdentifier("vvterm.settings.sync.copyDiagnostics")
        }
    }

    private var credentialRemovalSection: some View {
        Section {
            Button(role: .destructive, action: requestCredentialRemoval) {
                Label("Remove Credentials from iCloud Keychain", systemImage: "key.slash")
            }
            .accessibilityIdentifier("vvterm.settings.sync.removeCredentials")
        } footer: {
            Text("Credentials remain on this device. Existing app data in iCloud is not deleted.")
        }
    }

    private var storageStatus: LocalizedStringResource {
        contentSyncState.rowTitle
    }
}

private struct SyncSettingsDetailsCountRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let count: Int
    let accessibilityIdentifier: String

    var body: some View {
        LabeledContent {
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct SyncSettingsDetailsStatusRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let status: LocalizedStringResource

    var body: some View {
        LabeledContent {
            Text(status)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
