import Foundation

typealias VoiceInputRuntimeFactory = @MainActor () -> VoiceInputRuntimeOwner

@MainActor
final class VoiceInputRuntimeOwner {
    let audioService: AudioService
    let recordingOperation: VoiceRecordingOperationCoordinator

    init(
        audioService: AudioService,
        recordingOperation: VoiceRecordingOperationCoordinator
    ) {
        self.audioService = audioService
        self.recordingOperation = recordingOperation
    }

    func cancel() {
        recordingOperation.cancel()
        audioService.cancelRecording()
    }

    isolated deinit {
        cancel()
    }
}

@MainActor
final class VoiceInputRuntimeStore {
    let settingsStore: VoiceSettingsStore
    private let makeRuntime: VoiceInputRuntimeFactory
    private var runtimesByTabID: [UUID: VoiceInputRuntimeOwner] = [:]
    private var tabIDsByServerID: [UUID: Set<UUID>] = [:]

    init(
        settingsStore: VoiceSettingsStore,
        makeRuntime: @escaping VoiceInputRuntimeFactory
    ) {
        self.settingsStore = settingsStore
        self.makeRuntime = makeRuntime
    }

    func runtime(for tabID: UUID) -> VoiceInputRuntimeOwner {
        if let runtime = runtimesByTabID[tabID] {
            return runtime
        }
        let runtime = makeRuntime()
        runtimesByTabID[tabID] = runtime
        return runtime
    }

    func synchronize(tabIDs: Set<UUID>, for serverID: UUID) {
        let removedTabIDs = (tabIDsByServerID[serverID] ?? []).subtracting(tabIDs)
        for tabID in removedTabIDs {
            runtimesByTabID.removeValue(forKey: tabID)?.cancel()
        }
        if tabIDs.isEmpty {
            tabIDsByServerID.removeValue(forKey: serverID)
        } else {
            tabIDsByServerID[serverID] = tabIDs
        }
    }

    func removeAll() {
        let runtimes = Array(runtimesByTabID.values)
        runtimesByTabID.removeAll(keepingCapacity: false)
        tabIDsByServerID.removeAll(keepingCapacity: false)
        runtimes.forEach { $0.cancel() }
    }

    var runtimeCount: Int {
        runtimesByTabID.count
    }

    isolated deinit {
        runtimesByTabID.values.forEach { $0.cancel() }
    }
}

@MainActor
enum VoiceInputRuntimeLiveComposition {
    static func makeFactory(
        settingsStore: VoiceSettingsStore
    ) -> VoiceInputRuntimeFactory {
        {
            let speechRecognition = SpeechRecognitionService(
                selectedLanguageCode: {
                    settingsStore.currentSettings.languageCode
                }
            )
            let audioService = AudioService(
                permissionManager: AudioPermissionManager(),
                speechRecognitionService: speechRecognition,
                audioCaptureService: AudioCaptureService(),
                mlxWhisperProvider: MLXWhisperProvider(),
                mlxParakeetProvider: MLXParakeetProvider(),
                settingsReader: settingsStore,
                startupOperation: nil
            )
            return VoiceInputRuntimeOwner(
                audioService: audioService,
                recordingOperation: VoiceRecordingOperationCoordinator()
            )
        }
    }
}
