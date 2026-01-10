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

}
