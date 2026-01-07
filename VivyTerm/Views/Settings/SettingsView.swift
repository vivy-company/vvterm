//
//  SettingsView.swift
//  VivyTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

private extension View {
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

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

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $selection) {
                // Pro at top
                proNavigationRow
                    .tag(SettingsSelection.pro)
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
            .frame(minWidth: 200, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(200)
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
                                Text(storeManager.isPro ? "Manage subscription" : "Upgrade for unlimited features")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(storeManager.isPro ? "PRO" : "FREE")
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

                Section("Developer") {
                    NavigationLink {
                        DebugTerminalView()
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Terminal Debug", systemImage: "ant")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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
                .navigationSubtitle(storeManager.isPro ? "Manage your subscription" : "Upgrade for unlimited features")
        case .general:
            GeneralSettingsView()
                .navigationTitle("General")
                .navigationSubtitle("Appearance and preferences")
        case .terminal:
            TerminalSettingsView(fontName: $terminalFontName, fontSize: $terminalFontSize)
                .navigationTitle("Terminal")
                .navigationSubtitle("Font, theme, and connection settings")
        case .transcription:
            TranscriptionSettingsView()
                .navigationTitle("Transcription")
                .navigationSubtitle("Speech-to-text engine and models")
        case .keychain:
            KeychainSettingsView()
                .navigationTitle("SSH Keys")
                .navigationSubtitle("Manage stored SSH keys")
        case .sync:
            SyncSettingsView()
                .navigationTitle("Sync")
                .navigationSubtitle("iCloud sync and data management")
        case .about:
            AboutSettingsView()
                .navigationTitle("About")
                .navigationSubtitle("Version and links")
        case .none:
            ProSettingsView()
                .navigationTitle("VVTerm Pro")
                .navigationSubtitle(storeManager.isPro ? "Manage your subscription" : "Upgrade for unlimited features")
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

            Text("VVTerm Pro")
                .fontWeight(.medium)

            Spacer()

            Text(storeManager.isPro ? "PRO" : "FREE")
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
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private func settingsRow(_ title: String, icon: String, tag: SettingsSelection) -> some View {
        Label(title, systemImage: icon)
            .tag(tag)
    }
    #endif
}

// MARK: - Terminal Settings View

struct TerminalSettingsView: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    @AppStorage("terminalThemeName") private var themeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") private var themeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = false
    @AppStorage("terminalNotificationsEnabled") private var terminalNotificationsEnabled = true
    @AppStorage("terminalProgressEnabled") private var terminalProgressEnabled = true
    @AppStorage("terminalVoiceButtonEnabled") private var terminalVoiceButtonEnabled = true

    // Copy settings
    @AppStorage("terminalCopyTrimTrailingWhitespace") private var copyTrimTrailingWhitespace = true
    @AppStorage("terminalCopyCollapseBlankLines") private var copyCollapseBlankLines = false
    @AppStorage("terminalCopyStripShellPrompts") private var copyStripShellPrompts = false
    @AppStorage("terminalCopyFlattenCommands") private var copyFlattenCommands = false
    @AppStorage("terminalCopyRemoveBoxDrawing") private var copyRemoveBoxDrawing = false
    @AppStorage("terminalCopyStripAnsiCodes") private var copyStripAnsiCodes = true

    // SSH settings
    @AppStorage("sshKeepAliveEnabled") private var keepAliveEnabled = true
    @AppStorage("sshKeepAliveInterval") private var keepAliveInterval = 30
    @AppStorage("sshAutoReconnect") private var autoReconnect = true

    @State private var availableFonts: [String] = []
    @State private var themeNames: [String] = []

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font Family", selection: $fontName) {
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
                .disabled(availableFonts.isEmpty)

                HStack {
                    Text("Size: \(Int(fontSize))pt")
                        .frame(width: 100, alignment: .leading)
                    Slider(value: $fontSize, in: 8...24, step: 1)
                    Stepper("", value: $fontSize, in: 8...24, step: 1)
                        .labelsHidden()
                }
            }

            Section("Theme") {
                Toggle("Use different themes for Light/Dark mode", isOn: $usePerAppearanceTheme)

                if usePerAppearanceTheme {
                    Picker("Dark Mode Theme", selection: $themeName) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)

                    Picker("Light Mode Theme", selection: $themeNameLight) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)
                } else {
                    Picker("Theme", selection: $themeName) {
                        ForEach(themeNames, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    .disabled(themeNames.isEmpty)
                }
            }

            Section("Terminal Behavior") {
                Toggle("Enable terminal notifications", isOn: $terminalNotificationsEnabled)
                Toggle("Show progress overlays", isOn: $terminalProgressEnabled)
                Toggle("Show voice input button", isOn: $terminalVoiceButtonEnabled)
            }

            Section {
                Toggle("Trim trailing whitespace", isOn: $copyTrimTrailingWhitespace)
                Toggle("Collapse multiple blank lines", isOn: $copyCollapseBlankLines)
                Toggle("Strip shell prompts ($ #)", isOn: $copyStripShellPrompts)
                Toggle("Flatten multi-line commands", isOn: $copyFlattenCommands)
                Toggle("Remove box-drawing characters", isOn: $copyRemoveBoxDrawing)
                Toggle("Strip ANSI escape codes", isOn: $copyStripAnsiCodes)
            } header: {
                Text("Copy Text Processing")
            } footer: {
                Text("Transformations applied when copying text from terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH Connection") {
                Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
                Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)

                if keepAliveEnabled {
                    Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if availableFonts.isEmpty {
                availableFonts = loadSystemFonts()
            }
            if themeNames.isEmpty {
                themeNames = loadThemeNames()
            }
        }
    }

    #if os(macOS)
    private func loadSystemFonts() -> [String] {
        let fontManager = NSFontManager.shared
        return fontManager.availableFontFamilies.filter { familyName in
            guard let font = NSFont(name: familyName, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
    #else
    private func loadSystemFonts() -> [String] {
        ["Menlo", "Monaco", "SF Mono", "Courier New"]
    }
    #endif

    private func loadThemeNames() -> [String] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }

        let structuredPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        if FileManager.default.fileExists(atPath: structuredPath) {
            return loadThemesFromDirectory(structuredPath)
        }

        return loadThemesFromFlattenedResources(resourcePath)
    }

    private func loadThemesFromDirectory(_ path: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return files.filter { file in
            let fullPath = (path as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            return !isDir.boolValue && !file.hasPrefix(".")
        }.sorted()
    }

    private func loadThemesFromFlattenedResources(_ resourcePath: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) else { return [] }
        let knownNonThemes = Set(["Info", "Assets", "PkgInfo", "ghostty", "xterm-ghostty", "CodeSignature", "embedded", "_CodeSignature"])

        return files.filter { file in
            let fullPath = (resourcePath as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            guard !isDir.boolValue else { return false }
            guard !file.hasPrefix(".") else { return false }
            guard !file.contains(".") else { return false }
            guard !knownNonThemes.contains(file) else { return false }
            return true
        }.sorted()
    }
}

// MARK: - Transcription Settings View

struct TranscriptionSettingsView: View {
    @AppStorage("transcriptionProvider") private var provider = "system"
    @AppStorage("whisperModelId") private var whisperModelId = "mlx-community/whisper-tiny"
    @AppStorage("parakeetModelId") private var parakeetModelId = "mlx-community/parakeet-tdt-0.6b-v2"
    @AppStorage("transcriptionLanguage") private var language = "en"

    @StateObject private var whisperManager: MLXModelManager
    @StateObject private var parakeetManager: MLXModelManager

    private let languages = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("auto", "Auto-detect")
    ]

    init() {
        let whisper = MLXModelManager(kind: .whisper, modelId: UserDefaults.standard.string(forKey: "whisperModelId") ?? "mlx-community/whisper-tiny")
        let parakeet = MLXModelManager(kind: .parakeetTDT, modelId: UserDefaults.standard.string(forKey: "parakeetModelId") ?? "mlx-community/parakeet-tdt-0.6b-v2")
        _whisperManager = StateObject(wrappedValue: whisper)
        _parakeetManager = StateObject(wrappedValue: parakeet)
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $provider) {
                    Text("System (Apple)").tag("system")
                    #if arch(arm64)
                    Text("Whisper (MLX)").tag("whisper")
                    Text("Parakeet (MLX)").tag("parakeet")
                    #endif
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(providerDescription)
            }

            if provider == "system" {
                Section("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                }
            }

            #if arch(arm64)
            if provider == "whisper" {
                modelSection(
                    manager: whisperManager,
                    modelBinding: $whisperModelId,
                    models: [
                        ("mlx-community/whisper-tiny", "Tiny", "~39 MB"),
                        ("mlx-community/whisper-base", "Base", "~74 MB"),
                        ("mlx-community/whisper-small", "Small", "~244 MB"),
                        ("mlx-community/whisper-medium", "Medium", "~769 MB")
                    ]
                )
            }

            if provider == "parakeet" {
                modelSection(
                    manager: parakeetManager,
                    modelBinding: $parakeetModelId,
                    models: [
                        ("mlx-community/parakeet-tdt-0.6b-v2", "Parakeet TDT 0.6B", "~600 MB")
                    ]
                )
            }
            #endif

            storageSection
        }
        .formStyle(.grouped)
        .onAppear {
            whisperManager.refreshStatus()
            parakeetManager.refreshStatus()
        }
    }

    private var providerDescription: String {
        switch provider {
        case "system":
            return "Uses Apple's built-in speech recognition. Requires network for best results."
        case "whisper":
            return "OpenAI Whisper runs locally using MLX. Works offline after download."
        case "parakeet":
            return "NVIDIA Parakeet runs locally using MLX. Optimized for real-time transcription."
        default:
            return ""
        }
    }

    @ViewBuilder
    private func modelSection(
        manager: MLXModelManager,
        modelBinding: Binding<String>,
        models: [(String, String, String)]
    ) -> some View {
        Section {
            Picker("Model", selection: modelBinding) {
                ForEach(models, id: \.0) { id, name, size in
                    HStack {
                        Text(name)
                        Spacer()
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(id)
                }
            }
            .onChange(of: modelBinding.wrappedValue) { _, newValue in
                manager.modelId = newValue
                manager.refreshStatus()
            }

            modelStatusRow(manager: manager)

            if case .downloading(let progress) = manager.state {
                ProgressView(value: progress) {
                    Text("Downloading...")
                        .font(.caption)
                }
            }

            if manager.isModelAvailable {
                Button("Delete Model", role: .destructive) {
                    manager.removeModel()
                }
            }
        } header: {
            Text("Model")
        } footer: {
            if let repoSize = manager.repoSizeBytes {
                Text("Download size: \(ByteCountFormatter.string(fromByteCount: repoSize, countStyle: .file))")
            }
        }
    }

    @ViewBuilder
    private func modelStatusRow(manager: MLXModelManager) -> some View {
        HStack {
            Text("Status")
            Spacer()
            switch manager.state {
            case .idle:
                Button("Download") {
                    Task { await manager.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .downloading:
                Text("Downloading...")
                    .foregroundStyle(.orange)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let error):
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        #if arch(arm64)
        let activeManager = provider == "whisper" ? whisperManager : parakeetManager
        if activeManager.totalStorageBytes > 0 {
            Section("Storage") {
                HStack {
                    Text("Model Storage")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: activeManager.localStorageBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Total MLX Models")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: activeManager.totalStorageBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
        }
        #endif
    }
}

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

// MARK: - About Settings View

struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var appIcon: Image {
        #if os(macOS)
        if let nsImage = NSImage(named: "AppIcon") {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "terminal")
        #else
        if let uiImage = UIImage(named: "AppIcon") {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "terminal")
        #endif
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    appIcon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 3)

                    Text("VVTerm")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Professional SSH client\nfor macOS & iOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Section("Links") {
                Link(destination: URL(string: "https://vivy.dev")!) {
                    Label("Visit Website", systemImage: "globe")
                }

                Link(destination: URL(string: "https://github.com/vivy-company/vivyterm/issues")!) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }

                Link(destination: URL(string: "https://vivy.dev/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }

            Section {
                Text("© 2025 Vivy Technologies Co., Limited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
