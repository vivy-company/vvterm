//
//  SettingsView.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit

private extension View {
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}
#endif

// MARK: - Settings Selection

enum SettingsSelection: Hashable {
    case pro
    case general
    case terminal
    case transcription
    case keychain
    case sync
    case about
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("terminalFontName") private var terminalFontName = "Menlo"
    @AppStorage("terminalFontSize") private var terminalFontSize = 12.0

    @State private var selection: SettingsSelection? = .pro
    @StateObject private var storeManager = StoreManager.shared

    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $selection) {
                // Pro at top (not part of selection - has its own styling)
                Button {
                    selection = .pro
                } label: {
                    proNavigationRow
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Divider()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                settingsRow("General", icon: "gear", tag: .general)
                settingsRow("Terminal", icon: "terminal", tag: .terminal)
                settingsRow("Transcription", icon: "waveform", tag: .transcription)
                settingsRow("SSH Keys", icon: "key", tag: .keychain)
                settingsRow("Sync", icon: "icloud", tag: .sync)
                settingsRow("About", icon: "info.circle", tag: .about)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 240, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(240)
            .removingSidebarToggle()
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .principal) { Text("") }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
        #else
        NavigationStack {
            List {
                // Pro card at top
                Section {
                    NavigationLink {
                        ProSettingsView()
                            .navigationTitle("VVTerm Pro")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Color.orange, Color(red: 0.95, green: 0.5, blue: 0.2)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("VVTerm Pro")
                                    .font(.headline)
                                Text(storeManager.isPro ? String(localized: "Manage subscription") : String(localized: "Upgrade for unlimited features"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(storeManager.isPro ? String(localized: "PRO") : String(localized: "FREE"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(storeManager.isPro ? .white : .primary.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(storeManager.isPro
                                            ? Color.orange
                                            : Color.primary.opacity(0.12)
                                        )
                                )
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    NavigationLink {
                        GeneralSettingsView()
                            .navigationTitle("General")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("General", systemImage: "gear")
                    }

                    NavigationLink {
                        TerminalSettingsView(fontName: $terminalFontName, fontSize: $terminalFontSize)
                            .navigationTitle("Terminal")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                    }

                    NavigationLink {
                        TranscriptionSettingsView()
                            .navigationTitle("Transcription")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Transcription", systemImage: "waveform")
                    }

                    NavigationLink {
                        KeychainSettingsView()
                            .navigationTitle("SSH Keys")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("SSH Keys", systemImage: "key")
                    }

                    NavigationLink {
                        SyncSettingsView()
                            .navigationTitle("Sync")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Sync", systemImage: "icloud")
                    }

                    NavigationLink {
                        AboutSettingsView()
                            .navigationTitle("About")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .pro:
                            ProSettingsView()
                                .navigationTitle("VVTerm Pro")
                                .navigationSubtitle(storeManager.isPro
                                    ? String(localized: "Manage your subscription")
                                    : String(localized: "Upgrade for unlimited features")
                                )
        case .general:
                            GeneralSettingsView()
                                .navigationTitle("General")
                                .navigationSubtitle(String(localized: "Appearance and preferences"))
        case .terminal:
                            TerminalSettingsView(fontName: $terminalFontName, fontSize: $terminalFontSize)
                                .navigationTitle("Terminal")
                                .navigationSubtitle(String(localized: "Font, theme, and connection settings"))
        case .transcription:
                            TranscriptionSettingsView()
                                .navigationTitle("Transcription")
                                .navigationSubtitle(String(localized: "Speech-to-text engine and models"))
        case .keychain:
                            KeychainSettingsView()
                                .navigationTitle("SSH Keys")
                                .navigationSubtitle(String(localized: "Manage stored SSH keys"))
        case .sync:
                            SyncSettingsView()
                                .navigationTitle("Sync")
                                .navigationSubtitle(String(localized: "iCloud sync and data management"))
        case .about:
                            AboutSettingsView()
                                .navigationTitle("About")
                                .navigationSubtitle(String(localized: "Version and links"))
        case .none:
                            ProSettingsView()
                                .navigationTitle("VVTerm Pro")
                                .navigationSubtitle(storeManager.isPro
                                    ? String(localized: "Manage your subscription")
                                    : String(localized: "Upgrade for unlimited features")
                                )
        }
    }

    private var proNavigationRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.orange, Color(red: 0.95, green: 0.5, blue: 0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 24, height: 24)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text("Premium")
                .fontWeight(.medium)

            Spacer()

            Text(storeManager.isPro ? String(localized: "PRO") : String(localized: "FREE"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(storeManager.isPro ? .white : .primary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(storeManager.isPro
                            ? Color.orange
                            : Color.primary.opacity(0.12)
                        )
                )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func settingsRow(_ title: LocalizedStringKey, icon: String, tag: SettingsSelection) -> some View {
        Label(title, systemImage: icon)
            .tag(tag)
    }
    #endif
}

// MARK: - Preview

#Preview {
    SettingsView()
}
