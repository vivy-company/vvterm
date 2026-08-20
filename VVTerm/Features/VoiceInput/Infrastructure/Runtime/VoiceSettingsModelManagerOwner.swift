import Foundation

@MainActor
final class VoiceSettingsModelManagerOwner {
    typealias ManagerFactory = @MainActor (
        _ kind: MLXModelKind,
        _ selectedModelID: @escaping @MainActor () -> String
    ) -> MLXModelManager

    let settingsStore: VoiceSettingsStore
    let whisperManager: MLXModelManager
    let parakeetManager: MLXModelManager

    init(
        settingsStore: VoiceSettingsStore,
        makeManager: ManagerFactory
    ) {
        self.settingsStore = settingsStore
        whisperManager = makeManager(.whisper) {
            settingsStore.settings.whisperModelID
        }
        parakeetManager = makeManager(.parakeetTDT) {
            settingsStore.settings.parakeetModelID
        }
    }

    isolated deinit {
        whisperManager.shutdown()
        parakeetManager.shutdown()
    }

    func selectWhisperModel(_ modelID: String) {
        let previousModelID = settingsStore.settings.whisperModelID
        settingsStore.setWhisperModelID(modelID)
        guard settingsStore.settings.whisperModelID != previousModelID else { return }
        whisperManager.modelSelectionDidChange(from: previousModelID)
    }

    func selectParakeetModel(_ modelID: String) {
        let previousModelID = settingsStore.settings.parakeetModelID
        settingsStore.setParakeetModelID(modelID)
        guard settingsStore.settings.parakeetModelID != previousModelID else { return }
        parakeetManager.modelSelectionDidChange(from: previousModelID)
    }

    func refreshStatus() {
        whisperManager.refreshStatus()
        parakeetManager.refreshStatus()
    }

    func clearAllStorage() {
        whisperManager.clearAllStorage()
        parakeetManager.clearAllStorage()
        refreshStatus()
    }
}
