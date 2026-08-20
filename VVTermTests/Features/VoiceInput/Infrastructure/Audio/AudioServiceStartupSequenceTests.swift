import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct AudioServiceStartupSequenceTests {
    private enum TestError: Error {
        case staleAttempt
    }

    private final class SettingsReader: VoiceSettingsReading {
        let currentSettings = TranscriptionSettingsDefaults.settings
    }

    @Test
    func cancellationAfterMicrophonePromptSkipsSpeechPermissionRequest() async {
        let microphoneGate = CancellationIgnoringGate()
        var speechRequests = 0

        let task = Task {
            await AudioPermissionManager.requestPermissionSequence(
                includeSpeech: true,
                requestMicrophone: {
                    await microphoneGate.wait()
                    return true
                },
                requestSpeech: {
                    speechRequests += 1
                    return true
                }
            )
        }

        await microphoneGate.waitUntilStarted()
        task.cancel()
        microphoneGate.open()

        #expect(await task.value == false)
        #expect(speechRequests == 0)
    }

    @Test
    func cancelledPermissionContinuationCannotStartCaptureAfterForegrounding() async {
        let permissionGate = CancellationIgnoringGate()
        var operationIsCurrent = true
        var captureStarts = 0

        let task = Task {
            try await AudioService.runStartupSequence(
                lifecycleState: { activeLifecycle },
                operationIsCurrent: { operationIsCurrent },
                checkPermissions: { false },
                requestPermissions: {
                    await permissionGate.wait()
                    return true
                },
                startServices: {
                    captureStarts += 1
                }
            )
        }

        await permissionGate.waitUntilStarted()
        operationIsCurrent = false
        task.cancel()
        permissionGate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(captureStarts == 0)
    }

    @Test
    func replacedPermissionAttemptCannotStartOrCleanUpNewCapture() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstPermissionGate = CancellationIgnoringGate()
        var currentID = firstID
        var captureStarts: [UUID] = []

        let firstTask = Task {
            try await AudioService.runStartupSequence(
                lifecycleState: { activeLifecycle },
                operationIsCurrent: { currentID == firstID },
                checkPermissions: { false },
                requestPermissions: {
                    await firstPermissionGate.wait()
                    return true
                },
                startServices: { captureStarts.append(firstID) }
            )
        }
        await firstPermissionGate.waitUntilStarted()

        currentID = secondID
        try await AudioService.runStartupSequence(
            lifecycleState: { activeLifecycle },
            operationIsCurrent: { currentID == secondID },
            checkPermissions: { true },
            requestPermissions: { false },
            startServices: { captureStarts.append(secondID) }
        )

        firstPermissionGate.open()
        await #expect(throws: CancellationError.self) {
            try await firstTask.value
        }
        #expect(captureStarts == [secondID])
    }

    @Test
    func staleServiceFailureCannotCleanUpReplacementResourcesOrState() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstGate = CancellationIgnoringGate()
        var resourceReleases = 0
        let resources = AudioCaptureResources()
        resources.own { resourceReleases += 1 }
        let captureService = AudioCaptureService(captureResources: resources)
        let service = makeAudioService(
            audioCaptureService: captureService,
            startupOperation: { operationID, _ in
                if operationID == firstID {
                    await firstGate.wait()
                    throw TestError.staleAttempt
                }
            }
        )

        let firstTask = Task {
            try await service.startRecording(
                operationID: firstID,
                lifecycleState: { activeLifecycle }
            )
        }
        await firstGate.waitUntilStarted()

        try await service.startRecording(
            operationID: secondID,
            lifecycleState: { activeLifecycle }
        )
        #expect(service.isRecording)

        firstGate.open()
        await #expect(throws: CancellationError.self) {
            try await firstTask.value
        }
        #expect(service.isRecording)
        #expect(resourceReleases == 0)

        service.cancelRecording()
        #expect(resourceReleases == 1)
    }

    @Test
    func wrongOperationCannotStopTheCurrentRecording() async throws {
        let recordingID = UUID()
        let service = makeAudioService(
            audioCaptureService: AudioCaptureService(),
            startupOperation: { _, _ in }
        )

        try await service.startRecording(
            operationID: recordingID,
            lifecycleState: { activeLifecycle }
        )

        let staleResult = await service.stopRecording(operationID: UUID())

        #expect(staleResult.isEmpty)
        #expect(service.isRecording)
        service.cancelRecording()
    }

    @Test
    func staleProcessingSuccessCannotPublishOverAReplacement() async {
        let transcriptionGate = CancellationIgnoringGate()
        var operationIsCurrent = true
        var fallbackCalls = 0

        let task = Task {
            await AudioService.runProcessingSequence(
                operationIsCurrent: { operationIsCurrent },
                transcribe: {
                    await transcriptionGate.wait()
                    return "stale transcription"
                },
                fallback: { _ in
                    fallbackCalls += 1
                    return "stale fallback"
                }
            )
        }

        await transcriptionGate.waitUntilStarted()
        operationIsCurrent = false
        transcriptionGate.open()

        #expect(await task.value == nil)
        #expect(fallbackCalls == 0)
    }

    @Test
    func staleProcessingFailureCannotEnterFallbackForAReplacement() async {
        let transcriptionGate = CancellationIgnoringGate()
        var operationIsCurrent = true
        var fallbackCalls = 0

        let task = Task {
            await AudioService.runProcessingSequence(
                operationIsCurrent: { operationIsCurrent },
                transcribe: {
                    await transcriptionGate.wait()
                    throw TestError.staleAttempt
                },
                fallback: { _ in
                    fallbackCalls += 1
                    return "stale fallback"
                }
            )
        }

        await transcriptionGate.waitUntilStarted()
        operationIsCurrent = false
        transcriptionGate.open()

        #expect(await task.value == nil)
        #expect(fallbackCalls == 0)
    }

    @Test
    func currentProcessingFailureUsesFallbackOnce() async {
        var fallbackCalls = 0

        let text = await AudioService.runProcessingSequence(
            operationIsCurrent: { true },
            transcribe: { throw TestError.staleAttempt },
            fallback: { _ in
                fallbackCalls += 1
                return "fallback transcription"
            }
        )

        #expect(text == "fallback transcription")
        #expect(fallbackCalls == 1)
    }

    private var activeLifecycle: AudioCaptureLifecycleState {
        AudioCaptureLifecycleState(applicationIsActive: true, sceneIsActive: true)
    }

    private func makeAudioService(
        audioCaptureService: AudioCaptureService,
        startupOperation: @escaping AudioService.StartupOperation
    ) -> AudioService {
        let settingsReader = SettingsReader()
        return AudioService(
            permissionManager: AudioPermissionManager(),
            speechRecognitionService: SpeechRecognitionService(
                selectedLanguageCode: {
                    settingsReader.currentSettings.languageCode
                }
            ),
            audioCaptureService: audioCaptureService,
            mlxWhisperProvider: MLXWhisperProvider(),
            mlxParakeetProvider: MLXParakeetProvider(),
            settingsReader: settingsReader,
            startupOperation: startupOperation
        )
    }
}
