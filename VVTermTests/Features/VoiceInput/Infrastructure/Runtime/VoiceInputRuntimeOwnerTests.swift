import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class VoiceInputRuntimeOwnerTests: XCTestCase {
    private final class Persistence: VoiceSettingsPersisting {
        private var settings = TranscriptionSettingsDefaults.settings

        func loadSettings() -> VoiceSettings {
            settings
        }

        func saveSettings(_ settings: VoiceSettings) {
            self.settings = settings
        }
    }

    private final class SettingsReader: VoiceSettingsReading {
        let currentSettings = TranscriptionSettingsDefaults.settings
    }

    func testStoresKeepOneRuntimePerTabAndDoNotShareAcrossOwners() {
        var firstFactoryCalls = 0
        var secondFactoryCalls = 0
        let firstStore = VoiceInputRuntimeStore(settingsStore: makeSettingsStore()) {
            firstFactoryCalls += 1
            return self.makeRuntime()
        }
        let secondStore = VoiceInputRuntimeStore(settingsStore: makeSettingsStore()) {
            secondFactoryCalls += 1
            return self.makeRuntime()
        }
        let tabID = UUID()

        let firstRuntime = firstStore.runtime(for: tabID)
        let repeatedRuntime = firstStore.runtime(for: tabID)
        let secondRuntime = secondStore.runtime(for: tabID)

        XCTAssertTrue(firstRuntime === repeatedRuntime)
        XCTAssertFalse(firstRuntime === secondRuntime)
        XCTAssertEqual(firstFactoryCalls, 1)
        XCTAssertEqual(secondFactoryCalls, 1)
        XCTAssertEqual(firstStore.runtimeCount, 1)
        XCTAssertEqual(secondStore.runtimeCount, 1)
    }

    func testRemovingRuntimeCancelsActiveStartupAndRejectsItsLateCompletion() async {
        let startupGate = CancellationIgnoringGate()
        let runtime = makeRuntime(
            startupOperation: { _, _ in
                await startupGate.wait()
            }
        )
        let store = VoiceInputRuntimeStore(settingsStore: makeSettingsStore()) { runtime }
        let tabID = UUID()
        let serverID = UUID()
        store.synchronize(tabIDs: [tabID], for: serverID)
        let ownedRuntime = store.runtime(for: tabID)
        let lifecycle = AudioCaptureLifecycleState(
            applicationIsActive: true,
            sceneIsActive: true
        )
        let task = ownedRuntime.recordingOperation.startRecording(
            operation: { operationID in
                try await ownedRuntime.audioService.startRecording(
                    operationID: operationID,
                    lifecycleState: { lifecycle }
                )
            },
            onFailure: { _ in }
        )

        await startupGate.waitUntilStarted()
        store.synchronize(tabIDs: [], for: serverID)

        XCTAssertEqual(store.runtimeCount, 0)
        XCTAssertEqual(ownedRuntime.recordingOperation.phase, .idle)
        XCTAssertFalse(ownedRuntime.audioService.isRecording)

        startupGate.open()
        await task.value

        XCTAssertEqual(ownedRuntime.recordingOperation.phase, .idle)
        XCTAssertFalse(ownedRuntime.audioService.isRecording)
    }

    private func makeRuntime(
        startupOperation: AudioService.StartupOperation? = nil
    ) -> VoiceInputRuntimeOwner {
        let settingsReader = SettingsReader()
        let audioService = AudioService(
            permissionManager: AudioPermissionManager(),
            speechRecognitionService: SpeechRecognitionService(
                selectedLanguageCode: {
                    settingsReader.currentSettings.languageCode
                }
            ),
            audioCaptureService: AudioCaptureService(),
            mlxWhisperProvider: MLXWhisperProvider(),
            mlxParakeetProvider: MLXParakeetProvider(),
            settingsReader: settingsReader,
            startupOperation: startupOperation
        )
        return VoiceInputRuntimeOwner(
            audioService: audioService,
            recordingOperation: VoiceRecordingOperationCoordinator()
        )
    }

    private func makeSettingsStore() -> VoiceSettingsStore {
        VoiceSettingsStore(persistence: Persistence())
    }
}
