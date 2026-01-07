import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case system
    case mlxWhisper
    case mlxParakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "System (Apple Speech)"
        case .mlxWhisper:
            return "MLX Whisper"
        case .mlxParakeet:
            return "MLX Parakeet"
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
        if let raw = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.provider),
           let provider = TranscriptionProvider(rawValue: raw) {
            return provider
        }
        return TranscriptionSettingsDefaults.provider
    }

    static func currentWhisperModelId() -> String {
        UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId)
            ?? TranscriptionSettingsDefaults.mlxWhisperModelId
    }

    static func currentParakeetModelId() -> String {
        UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.mlxParakeetModelId)
            ?? TranscriptionSettingsDefaults.mlxParakeetModelId
    }
}
