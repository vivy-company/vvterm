import Foundation

nonisolated struct TranscriptionSettingsKeys {
    static let provider = "transcriptionProvider"
    static let mlxWhisperModelId = "mlxWhisperModelId"
    static let mlxParakeetModelId = "mlxParakeetModelId"
    static let language = "transcriptionLanguage"
    static let terminalVoiceButtonEnabled = "terminalVoiceButtonEnabled"

    static let legacyWhisperModelID = "whisperModelId"
    static let legacyParakeetModelID = "parakeetModelId"
}

nonisolated struct TranscriptionSettingsDefaults {
    static let provider: TranscriptionProvider = .system
    static let mlxWhisperModelId = MLXModelCatalog.defaultModelID(for: .whisper)
    static let mlxParakeetModelId = MLXModelCatalog.defaultModelID(for: .parakeetTDT)
    static let language = "en"
    static let autoLanguageCode = "auto"
    static let terminalVoiceButtonEnabled = true

    static var settings: VoiceSettings {
        VoiceSettings(
            provider: provider,
            whisperModelID: mlxWhisperModelId,
            parakeetModelID: mlxParakeetModelId,
            languageCode: language,
            terminalVoiceButtonEnabled: terminalVoiceButtonEnabled
        )
    }
}

@MainActor
final class UserDefaultsVoiceSettingsPersistence: VoiceSettingsPersisting {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadSettings() -> VoiceSettings {
        let settings = VoiceSettings(
            provider: loadProvider(),
            whisperModelID: loadModelID(
                currentKey: TranscriptionSettingsKeys.mlxWhisperModelId,
                legacyKey: TranscriptionSettingsKeys.legacyWhisperModelID,
                kind: .whisper
            ),
            parakeetModelID: loadModelID(
                currentKey: TranscriptionSettingsKeys.mlxParakeetModelId,
                legacyKey: TranscriptionSettingsKeys.legacyParakeetModelID,
                kind: .parakeetTDT
            ),
            languageCode: loadLanguageCode(),
            terminalVoiceButtonEnabled: loadTerminalVoiceButtonEnabled()
        )
        saveSettings(settings)
        defaults.removeObject(forKey: TranscriptionSettingsKeys.legacyWhisperModelID)
        defaults.removeObject(forKey: TranscriptionSettingsKeys.legacyParakeetModelID)
        return settings
    }

    func saveSettings(_ settings: VoiceSettings) {
        defaults.set(settings.provider.rawValue, forKey: TranscriptionSettingsKeys.provider)
        defaults.set(settings.whisperModelID, forKey: TranscriptionSettingsKeys.mlxWhisperModelId)
        defaults.set(settings.parakeetModelID, forKey: TranscriptionSettingsKeys.mlxParakeetModelId)
        defaults.set(settings.languageCode, forKey: TranscriptionSettingsKeys.language)
        defaults.set(
            settings.terminalVoiceButtonEnabled,
            forKey: TranscriptionSettingsKeys.terminalVoiceButtonEnabled
        )
    }

    private func loadProvider() -> TranscriptionProvider {
        guard let rawValue = defaults.string(forKey: TranscriptionSettingsKeys.provider) else {
            return TranscriptionSettingsDefaults.provider
        }
        switch rawValue {
        case "whisper":
            return .mlxWhisper
        case "parakeet":
            return .mlxParakeet
        default:
            return TranscriptionProvider(rawValue: rawValue) ?? TranscriptionSettingsDefaults.provider
        }
    }

    private func loadModelID(
        currentKey: String,
        legacyKey: String,
        kind: MLXModelKind
    ) -> String {
        let savedModelID = defaults.string(forKey: currentKey)
            ?? defaults.string(forKey: legacyKey)
            ?? MLXModelCatalog.defaultModelID(for: kind)
        return MLXModelLegacyMigration.resolveModelID(savedModelID, kind: kind).modelID
    }

    private func loadLanguageCode() -> String {
        let savedLanguage = defaults.string(forKey: TranscriptionSettingsKeys.language)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let savedLanguage, !savedLanguage.isEmpty else {
            return TranscriptionSettingsDefaults.language
        }
        return savedLanguage
    }

    private func loadTerminalVoiceButtonEnabled() -> Bool {
        guard defaults.object(forKey: TranscriptionSettingsKeys.terminalVoiceButtonEnabled) != nil else {
            return TranscriptionSettingsDefaults.terminalVoiceButtonEnabled
        }
        return defaults.bool(forKey: TranscriptionSettingsKeys.terminalVoiceButtonEnabled)
    }
}
