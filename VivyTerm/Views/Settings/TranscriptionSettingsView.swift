//
//  TranscriptionSettingsView.swift
//  VivyTerm
//

import SwiftUI

// MARK: - Transcription Settings View

struct TranscriptionSettingsView: View {
    @AppStorage("transcriptionProvider") private var provider = "system"
    @AppStorage("whisperModelId") private var whisperModelId = "mlx-community/whisper-tiny"
    @AppStorage("parakeetModelId") private var parakeetModelId = "mlx-community/parakeet-tdt-0.6b-v2"
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
                        ("mlx-community/whisper-tiny", String(localized: "Tiny"), "~39 MB"),
                        ("mlx-community/whisper-base", String(localized: "Base"), "~74 MB"),
                        ("mlx-community/whisper-small", String(localized: "Small"), "~244 MB"),
                        ("mlx-community/whisper-medium", String(localized: "Medium"), "~769 MB")
                    ]
                )
            }

            if provider == "parakeet" {
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
            whisperManager.refreshStatus()
            parakeetManager.refreshStatus()
        }
    }

    private var providerDescription: String {
        switch provider {
        case "system":
            return String(localized: "Uses Apple's built-in speech recognition. Requires network for best results.")
        case "whisper":
            return String(localized: "OpenAI Whisper runs locally using MLX. Works offline after download.")
        case "parakeet":
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
            .onChange(of: modelBinding.wrappedValue) { _, newValue in
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
                Button("Clear All Storage", role: .destructive) {
                    MLXModelManager.clearAllStorage()
                    whisperManager.refreshStatus()
                    parakeetManager.refreshStatus()
                }
            }
        }
        #endif
    }
}
