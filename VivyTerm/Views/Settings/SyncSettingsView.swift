//
//  SyncSettingsView.swift
//  VivyTerm
//

import SwiftUI

// MARK: - Sync Settings View

struct SyncSettingsView: View {
    @ObservedObject private var cloudKit = CloudKitManager.shared
    @ObservedObject private var serverManager = ServerManager.shared
    @AppStorage("iCloudSyncEnabled") private var syncEnabled = true

    @State private var isSyncing = false
    @State private var showingSyncConfirmation = false
    @State private var showingClearDataConfirmation = false
    @State private var showingResetCloudKitConfirmation = false
    @State private var syncError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable iCloud Sync", isOn: $syncEnabled)

                HStack {
                    Label("iCloud Account", systemImage: "icloud")
                    Spacer()
                    statusBadge
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Sync your servers and workspaces across all your Apple devices.")
            }

            if syncEnabled {
                Section("Sync Status") {
                    HStack {
                        Text("Status")
                        Spacer()
                        syncStatusView
                    }

                    if let lastSync = cloudKit.lastSyncDate {
                        HStack {
                            Text("Last Synced")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if case .error(let message) = cloudKit.syncStatus {
                        HStack {
                            Text("Error")
                            Spacer()
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Data") {
                    HStack {
                        Label("Workspaces", systemImage: "folder")
                        Spacer()
                        Text("\(serverManager.workspaces.count)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Servers", systemImage: "server.rack")
                        Spacer()
                        Text("\(serverManager.servers.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        showingSyncConfirmation = true
                    } label: {
                        HStack {
                            Label("Force Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isSyncing || !cloudKit.isAvailable)

                    Button(role: .destructive) {
                        showingClearDataConfirmation = true
                    } label: {
                        Label("Clear Local Data & Re-sync", systemImage: "trash")
                    }
                    .disabled(isSyncing || !cloudKit.isAvailable)

                    Button(role: .destructive) {
                        showingResetCloudKitConfirmation = true
                    } label: {
                        Label("Reset iCloud (Delete All & Re-upload)", systemImage: "icloud.slash")
                    }
                    .disabled(isSyncing || !cloudKit.isAvailable)
                } footer: {
                    Text("Force sync fetches latest data from iCloud. Clear & re-sync removes local data and downloads fresh. Reset iCloud deletes ALL cloud data and uploads your local data fresh (fixes duplicates).")
                }
            }

            if let error = syncError {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                    }
                }
            }

            // Debug section when CloudKit is unavailable
            if !cloudKit.isAvailable {
                Section {
                    HStack {
                        Text("Account Status")
                        Spacer()
                        Text(cloudKit.accountStatusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Container")
                        Spacer()
                        Text("iCloud.com.vivy.vivyterm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            await cloudKit.forceSync()
                        }
                    } label: {
                        Label("Re-check iCloud Status", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Make sure you are signed into iCloud in Settings and iCloud Drive is enabled. Check Console.app for 'CloudKit' logs for more details.")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Force Sync", isPresented: $showingSyncConfirmation) {
            Button("Sync Now") {
                performForceSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will fetch the latest data from iCloud and may take a moment.")
        }
        .alert("Clear Local Data", isPresented: $showingClearDataConfirmation) {
            Button("Clear & Re-sync", role: .destructive) {
                performClearAndResync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all local data and download fresh from iCloud. Any unsynced local changes will be lost.")
        }
        .alert("Reset iCloud Data", isPresented: $showingResetCloudKitConfirmation) {
            Button("Delete All & Re-upload", role: .destructive) {
                performResetCloudKit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will DELETE ALL data from iCloud and upload your current local data. Use this to fix duplicate records.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if cloudKit.isAvailable {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Not Available", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch cloudKit.syncStatus {
        case .idle:
            Label("Synced", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing...")
            }
            .foregroundStyle(.orange)
        case .error:
            Label("Error", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .offline:
            Label("Offline", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func performForceSync() {
        isSyncing = true
        syncError = nil

        Task {
            await cloudKit.forceSync()
            await serverManager.loadData()
            await MainActor.run {
                if let error = serverManager.error {
                    syncError = error
                }
                isSyncing = false
            }
        }
    }

    private func performClearAndResync() {
        isSyncing = true
        syncError = nil

        Task {
            await serverManager.clearLocalDataAndResync()
            await MainActor.run {
                if let error = serverManager.error {
                    syncError = error
                }
                isSyncing = false
            }
        }
    }

    private func performResetCloudKit() {
        isSyncing = true
        syncError = nil

        Task {
            do {
                // 1. Delete all CloudKit records
                try await cloudKit.deleteAllRecords()

                // 2. Re-upload local data
                for workspace in serverManager.workspaces {
                    try await cloudKit.saveWorkspace(workspace)
                }
                for server in serverManager.servers {
                    try await cloudKit.saveServer(server)
                }

                await MainActor.run {
                    syncError = nil
                    isSyncing = false
                }
            } catch {
                await MainActor.run {
                    syncError = error.localizedDescription
                    isSyncing = false
                }
            }
        }
    }
}
