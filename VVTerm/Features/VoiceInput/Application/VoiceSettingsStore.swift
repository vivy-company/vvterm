import Combine

@MainActor
protocol VoiceSettingsReading: AnyObject {
    var currentSettings: VoiceSettings { get }
}

@MainActor
protocol VoiceSettingsPersisting: AnyObject {
    func loadSettings() -> VoiceSettings
    func saveSettings(_ settings: VoiceSettings)
}

@MainActor
final class VoiceSettingsStore: ObservableObject, VoiceSettingsReading {
    @Published private(set) var settings: VoiceSettings

    private let persistence: any VoiceSettingsPersisting

    init(persistence: any VoiceSettingsPersisting) {
        self.persistence = persistence
        settings = persistence.loadSettings()
    }

    var currentSettings: VoiceSettings { settings }

    func setProvider(_ provider: TranscriptionProvider) {
        update { $0.provider = provider }
    }

    func setWhisperModelID(_ modelID: String) {
        update { $0.whisperModelID = modelID }
    }

    func setParakeetModelID(_ modelID: String) {
        update { $0.parakeetModelID = modelID }
    }

    func setLanguageCode(_ languageCode: String) {
        update { $0.languageCode = languageCode }
    }

    func setTerminalVoiceButtonEnabled(_ isEnabled: Bool) {
        update { $0.terminalVoiceButtonEnabled = isEnabled }
    }

    func useSystemProviderWhenMLXIsUnavailable() {
        guard settings.provider != .system else { return }
        setProvider(.system)
    }

    private func update(_ mutate: (inout VoiceSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        guard updated != settings else { return }
        settings = updated
        persistence.saveSettings(updated)
    }
}
