//
//  TranscriptionSettingsView.swift
//  VivyTerm
//

import SwiftUI

// MARK: - Transcription Settings View

struct TranscriptionSettingsView: View {
    @AppStorage(TranscriptionSettingsKeys.provider) private var provider = TranscriptionSettingsDefaults.provider.rawValue
    @AppStorage(TranscriptionSettingsKeys.mlxWhisperModelId) private var whisperModelId = TranscriptionSettingsDefaults.mlxWhisperModelId
    @AppStorage(TranscriptionSettingsKeys.mlxParakeetModelId) private var parakeetModelId = TranscriptionSettingsDefaults.mlxParakeetModelId
    @AppStorage("transcriptionLanguage") private var language = "en"

    @StateObject private var whisperManager: MLXModelManager
    @StateObject private var parakeetManager: MLXModelManager

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

    init() {
        let whisper = MLXModelManager(kind: .whisper, modelId: Self.resolveWhisperModelId())
        let parakeet = MLXModelManager(kind: .parakeetTDT, modelId: Self.resolveParakeetModelId())
        _whisperManager = StateObject(wrappedValue: whisper)
        _parakeetManager = StateObject(wrappedValue: parakeet)
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $provider) {
                    Text("System (Apple)").tag(TranscriptionProvider.system.rawValue)
                    #if arch(arm64)
                    Text("Whisper (MLX)").tag(TranscriptionProvider.mlxWhisper.rawValue)
                    Text("Parakeet (MLX)").tag(TranscriptionProvider.mlxParakeet.rawValue)
                    #endif
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(providerDescription)
            }

            if provider == TranscriptionProvider.system.rawValue {
                Section("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                }
            }

            #if arch(arm64)
            if provider == TranscriptionProvider.mlxWhisper.rawValue {
                modelSection(
                    manager: whisperManager,
                    modelBinding: $whisperModelId,
                    models: [
                        ("mlx-community/whisper-tiny-mlx", String(localized: "Tiny"), "~39 MB"),
                        ("mlx-community/whisper-base-mlx", String(localized: "Base"), "~74 MB"),
                        ("mlx-community/whisper-small-mlx", String(localized: "Small"), "~244 MB"),
                        ("mlx-community/whisper-medium-mlx-8bit", String(localized: "Medium (8-bit)"), "~400 MB"),
                        ("mlx-community/whisper-medium-mlx-q4", String(localized: "Medium (Q4)"), "~250 MB"),
                        ("mlx-community/whisper-medium-mlx-fp32", String(localized: "Medium (FP32)"), "~1.5 GB")
                    ]
                )
            }

            if provider == TranscriptionProvider.mlxParakeet.rawValue {
                modelSection(
                    manager: parakeetManager,
                    modelBinding: $parakeetModelId,
                    models: [
                        ("mlx-community/parakeet-tdt-0.6b-v2", String(localized: "Parakeet TDT 0.6B"), "~600 MB")
                    ]
                )
            }
            #endif

            storageSection
        }
        .formStyle(.grouped)
        .onAppear {
            migrateLegacySettings()
            whisperManager.refreshStatus()
            parakeetManager.refreshStatus()
        }
    }

    private var providerDescription: String {
        switch provider {
        case TranscriptionProvider.system.rawValue:
            return String(localized: "Uses Apple's built-in speech recognition. Requires network for best results.")
        case TranscriptionProvider.mlxWhisper.rawValue:
            return String(localized: "OpenAI Whisper runs locally using MLX. Works offline after download.")
        case TranscriptionProvider.mlxParakeet.rawValue:
            return String(localized: "NVIDIA Parakeet runs locally using MLX. Optimized for real-time transcription.")
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
            .onChangeCompat(of: modelBinding.wrappedValue) { newValue in
                manager.modelId = newValue
                manager.refreshStatus()
            }

            modelStatusRow(manager: manager)

            if case .downloading(let progress) = manager.state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        if progress.totalBytes > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: progress.bytesDownloaded, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
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
                Button("Delete Model", role: .destructive) {
                    manager.removeModel()
                }
                .padding(.top, 4)
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
    private var storageSection: some View {
        #if arch(arm64)
        let activeManager = provider == TranscriptionProvider.mlxWhisper.rawValue ? whisperManager : parakeetManager
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
                Button("Clear All Storage", role: .destructive) {
                    MLXModelManager.clearAllStorage()
                    whisperManager.refreshStatus()
                    parakeetManager.refreshStatus()
                }
            }
        }
        #endif
    }

    private static func resolveWhisperModelId() -> String {
        let defaults = UserDefaults.standard
        if let current = defaults.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId) {
            return current
        }
        if let legacy = defaults.string(forKey: "whisperModelId") {
            defaults.set(legacy, forKey: TranscriptionSettingsKeys.mlxWhisperModelId)
            return legacy
        }
        return TranscriptionSettingsDefaults.mlxWhisperModelId
    }

    private static func resolveParakeetModelId() -> String {
        let defaults = UserDefaults.standard
        if let current = defaults.string(forKey: TranscriptionSettingsKeys.mlxParakeetModelId) {
            return current
        }
        if let legacy = defaults.string(forKey: "parakeetModelId") {
            defaults.set(legacy, forKey: TranscriptionSettingsKeys.mlxParakeetModelId)
            return legacy
        }
        return TranscriptionSettingsDefaults.mlxParakeetModelId
    }

    private func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        if let legacyProvider = defaults.string(forKey: TranscriptionSettingsKeys.provider) {
            if legacyProvider == "whisper" {
                defaults.set(TranscriptionProvider.mlxWhisper.rawValue, forKey: TranscriptionSettingsKeys.provider)
                provider = TranscriptionProvider.mlxWhisper.rawValue
            } else if legacyProvider == "parakeet" {
                defaults.set(TranscriptionProvider.mlxParakeet.rawValue, forKey: TranscriptionSettingsKeys.provider)
                provider = TranscriptionProvider.mlxParakeet.rawValue
            }
        }

        if defaults.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId) == nil,
           let legacy = defaults.string(forKey: "whisperModelId") {
            defaults.set(legacy, forKey: TranscriptionSettingsKeys.mlxWhisperModelId)
            whisperModelId = legacy
        }

        if defaults.string(forKey: TranscriptionSettingsKeys.mlxParakeetModelId) == nil,
           let legacy = defaults.string(forKey: "parakeetModelId") {
            defaults.set(legacy, forKey: TranscriptionSettingsKeys.mlxParakeetModelId)
            parakeetModelId = legacy
        }
    }
}
