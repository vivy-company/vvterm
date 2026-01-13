import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case system
    case mlxWhisper
    case mlxParakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "System (Apple Speech)")
        case .mlxWhisper:
            return String(localized: "MLX Whisper")
        case .mlxParakeet:
            return String(localized: "MLX Parakeet")
        }
    }
}

struct TranscriptionSettingsKeys {
    static let provider = "transcriptionProvider"
    static let mlxWhisperModelId = "mlxWhisperModelId"
    static let mlxParakeetModelId = "mlxParakeetModelId"
}

struct TranscriptionSettingsDefaults {
    static let provider: TranscriptionProvider = .system
    static let mlxWhisperModelId = "mlx-community/whisper-tiny-mlx"
    static let mlxParakeetModelId = "mlx-community/parakeet-tdt-0.6b-v2"
}

struct TranscriptionSettingsStore {
    static func currentProvider() -> TranscriptionProvider {
        guard let raw = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.provider) else {
            return TranscriptionSettingsDefaults.provider
        }
        if let provider = TranscriptionProvider(rawValue: raw) {
            return provider
        }
        switch raw {
        case "whisper":
            return .mlxWhisper
        case "parakeet":
            return .mlxParakeet
        default:
            return TranscriptionSettingsDefaults.provider
        }
    }

    static func currentWhisperModelId() -> String {
        let raw: String
        if let modelId = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId) {
            raw = modelId
        } else if let legacy = UserDefaults.standard.string(forKey: "whisperModelId") {
            raw = legacy
        } else {
            raw = TranscriptionSettingsDefaults.mlxWhisperModelId
        }
        return normalizedWhisperModelId(raw)
    }

    static func currentParakeetModelId() -> String {
        if let modelId = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.mlxParakeetModelId) {
            return modelId
        }
        if let legacy = UserDefaults.standard.string(forKey: "parakeetModelId") {
            return legacy
        }
        return TranscriptionSettingsDefaults.mlxParakeetModelId
    }

    private static func normalizedWhisperModelId(_ modelId: String) -> String {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TranscriptionSettingsDefaults.mlxWhisperModelId }
        if trimmed == "mlx-community/whisper-medium-mlx" {
            return "mlx-community/whisper-medium-mlx-8bit"
        }
        if trimmed.hasSuffix("-mlx") { return trimmed }
        if trimmed.hasPrefix("mlx-community/whisper-") {
            return "\(trimmed)-mlx"
        }
        return trimmed
    }
}
