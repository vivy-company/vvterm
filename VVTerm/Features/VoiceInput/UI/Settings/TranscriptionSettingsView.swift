//
//  TranscriptionSettingsView.swift
//  VVTerm
//

import SwiftUI

// MARK: - Transcription Settings View

struct TranscriptionSettingsView: View {
    @ObservedObject private var settingsStore: VoiceSettingsStore
    @ObservedObject private var whisperManager: MLXModelManager
    @ObservedObject private var parakeetManager: MLXModelManager

    private let modelManagers: VoiceSettingsModelManagerOwner
    @State private var isShowingRemoveAllConfirmation = false

    private let mlxAvailable = MLXAudioSupport.isSupported

    private let languages = [
        ("en", String(localized: "English")),
        ("es", String(localized: "Spanish")),
        ("fr", String(localized: "French")),
        ("de", String(localized: "German")),
        ("ja", String(localized: "Japanese")),
        ("zh", String(localized: "Chinese")),
        ("ko", String(localized: "Korean")),
        ("pt", String(localized: "Portuguese")),
        ("ru", String(localized: "Russian")),
        ("auto", String(localized: "Auto-detect"))
    ]

    init(modelManagers: VoiceSettingsModelManagerOwner) {
        self.modelManagers = modelManagers
        _settingsStore = ObservedObject(wrappedValue: modelManagers.settingsStore)
        _whisperManager = ObservedObject(wrappedValue: modelManagers.whisperManager)
        _parakeetManager = ObservedObject(wrappedValue: modelManagers.parakeetManager)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show in Terminal", isOn: terminalVoiceButtonBinding)
            } header: {
                Text("Access")
                    .padding(.top, 8)
            } footer: {
                Text("You can also use Command–Shift–M with a hardware keyboard.")
            }

            Section {
                Picker("Engine", selection: providerBinding) {
                    Text("System (Apple)").tag(TranscriptionProvider.system)
                    #if arch(arm64)
                    if mlxAvailable {
                        Text("Whisper (MLX)").tag(TranscriptionProvider.mlxWhisper)
                        Text("Parakeet (MLX)").tag(TranscriptionProvider.mlxParakeet)
                    }
                    #endif
                }

                if provider == .system || provider == .mlxWhisper {
                    Picker("Language", selection: languageBinding) {
                        ForEach(languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                }
            } header: {
                Text("Transcription")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(providerDescription)

                    if (provider == .system || provider == .mlxWhisper),
                       language == TranscriptionSettingsDefaults.autoLanguageCode {
                        if provider == .system {
                            Text("Auto-detect uses your device language.")
                        } else {
                            Text("Auto-detect identifies the spoken language before transcribing.")
                        }
                    }
                }
            }

            #if arch(arm64)
            if mlxAvailable && provider == .mlxWhisper {
                modelSection(
                    manager: whisperManager,
                    modelBinding: whisperModelBinding,
                    models: MLXModelCatalog.options(for: .whisper)
                )
            }

            if mlxAvailable && provider == .mlxParakeet {
                modelSection(
                    manager: parakeetManager,
                    modelBinding: parakeetModelBinding,
                    models: MLXModelCatalog.options(for: .parakeetTDT),
                    footnote: String(localized: "Parakeet supports English only.")
                )
            }
            #endif

            downloadedModelsSection
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.transcription")
        .confirmationDialog(
            "Remove All Downloaded Models?",
            isPresented: $isShowingRemoveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All Downloaded Models", role: .destructive) {
                modelManagers.clearAllStorage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voice input models must be downloaded again before they can work offline.")
        }
        .onAppear {
            if !mlxAvailable {
                settingsStore.useSystemProviderWhenMLXIsUnavailable()
            }
            modelManagers.refreshStatus()
        }
    }

    private var provider: TranscriptionProvider {
        settingsStore.settings.provider
    }

    private var language: String {
        settingsStore.settings.languageCode
    }

    private var providerBinding: Binding<TranscriptionProvider> {
        Binding(
            get: { settingsStore.settings.provider },
            set: { settingsStore.setProvider($0) }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.languageCode },
            set: { settingsStore.setLanguageCode($0) }
        )
    }

    private var terminalVoiceButtonBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.terminalVoiceButtonEnabled },
            set: { settingsStore.setTerminalVoiceButtonEnabled($0) }
        )
    }

    private var whisperModelBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.whisperModelID },
            set: { modelManagers.selectWhisperModel($0) }
        )
    }

    private var parakeetModelBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.parakeetModelID },
            set: { modelManagers.selectParakeetModel($0) }
        )
    }

    private var providerDescription: String {
        guard mlxAvailable else {
            return MLXAudioSupport.unavailableDescription
        }

        switch provider {
        case .system:
            return String(localized: "Uses Apple's built-in speech recognition. Requires network for best results.")
        case .mlxWhisper:
            return String(localized: "Whisper runs on this device and works offline after download.")
        case .mlxParakeet:
            return String(localized: "Parakeet runs on this device and works offline after download.")
        }
    }

    @ViewBuilder
    private func modelSection(
        manager: MLXModelManager,
        modelBinding: Binding<String>,
        models: [MLXModelOption],
        footnote: String? = nil
    ) -> some View {
        Section {
            Picker("Model", selection: modelBinding) {
                ForEach(models) { option in
                    HStack {
                        Text(option.title)
                        Spacer()
                        Text(option.downloadSizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(option.id)
                }
            }

            modelStatusRow(manager: manager)

            if manager.localStorageBytes > 0 {
                LabeledContent("On This Device") {
                    Text(storageSizeLabel(manager.localStorageBytes))
                        .foregroundStyle(.secondary)
                }
            } else if let repoSize = manager.repoSizeBytes {
                LabeledContent("Download Size") {
                    Text(storageSizeLabel(repoSize))
                        .foregroundStyle(.secondary)
                }
            }

            if case .downloading(let progress) = manager.state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        if progress.totalBytes > 0 {
                            Text(String(format: String(localized: "%@ / %@"),
                                        ByteCountFormatter.string(fromByteCount: progress.bytesDownloaded, countStyle: .file),
                                        ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)))
                        } else {
                            Text("Downloading...")
                        }
                        Spacer()
                        if let eta = progress.estimatedSecondsRemaining, eta > 0 {
                            Text(formatETA(eta))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if manager.isModelAvailable {
                Button("Remove Download", role: .destructive) {
                    manager.removeModel()
                }
                .padding(.top, 4)
            }
        } header: {
            Text("Offline Model")
        } footer: {
            if let footnote {
                Text(footnote)
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
            case .checkingLegacyDownload:
                Label("Checking old download...", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .downloading:
                Text("Downloading...")
                    .foregroundStyle(.orange)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .updateRequired:
                VStack(alignment: .trailing, spacing: 6) {
                    Label("Update Required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if MLXModelCatalog.downloadManifest(for: manager.modelId, kind: manager.kind) != nil {
                        Button("Download Update") {
                            Task { await manager.downloadModel() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button("Remove Old Download", role: .destructive) {
                        manager.removeIncompatibleDownload()
                    }
                    .controlSize(.small)
                }
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
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(format: String(localized: "%llds remaining"), seconds)
        } else if seconds < 3600 {
            let minutes = seconds / 60
            return String(format: String(localized: "%lldm remaining"), minutes)
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return String(format: String(localized: "%lldh %lldm remaining"), hours, minutes)
        }
    }

    @ViewBuilder
    private var downloadedModelsSection: some View {
        #if arch(arm64)
        if mlxAvailable && shouldShowDownloadedModels {
            Section("Downloaded Models") {
                LabeledContent("All Models") {
                    Text(storageSizeLabel(totalModelStorageBytes))
                        .foregroundStyle(.secondary)
                }

                Button("Remove All Downloaded Models", role: .destructive) {
                    isShowingRemoveAllConfirmation = true
                }
            }
        }
        #endif
    }

    private var activeMLXManager: MLXModelManager? {
        switch provider {
        case .system:
            nil
        case .mlxWhisper:
            whisperManager
        case .mlxParakeet:
            parakeetManager
        }
    }

    private var totalModelStorageBytes: Int64 {
        max(whisperManager.totalStorageBytes, parakeetManager.totalStorageBytes)
    }

    private var shouldShowDownloadedModels: Bool {
        guard totalModelStorageBytes > 0 else { return false }
        guard let activeMLXManager else { return true }
        return totalModelStorageBytes > activeMLXManager.localStorageBytes
    }

    private func storageSizeLabel(_ byteCount: Int64) -> String {
        MLXModelStorageSizeFormatter.string(fromByteCount: byteCount)
    }

}
