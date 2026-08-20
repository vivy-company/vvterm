import Foundation
import Combine
import os.log

private extension TranscriptionProvider {
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

@MainActor
class AudioService: NSObject, ObservableObject {
    typealias StartupOperation = @MainActor (
        UUID,
        @escaping @MainActor () -> AudioCaptureLifecycleState
    ) async throws -> Void

    private enum RecordingState {
        case idle
        case starting(operationID: UUID, provider: TranscriptionProvider)
        case recording(operationID: UUID, provider: TranscriptionProvider)
        case processing(operationID: UUID, provider: TranscriptionProvider)

        var operationID: UUID? {
            switch self {
            case .idle:
                return nil
            case .starting(let operationID, _),
                 .recording(let operationID, _),
                 .processing(let operationID, _):
                return operationID
            }
        }

        var provider: TranscriptionProvider? {
            switch self {
            case .idle:
                return nil
            case .starting(_, let provider),
                 .recording(_, let provider),
                 .processing(_, let provider):
                return provider
            }
        }

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    private let logger = Logger.audio
    @Published private var recordingState: RecordingState = .idle
    @Published var transcribedText = ""
    @Published var partialTranscription = ""
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0
    @Published var permissionStatus: AudioPermissionManager.PermissionStatus = .notDetermined

    private let permissionManager: AudioPermissionManager
    private let speechRecognitionService: SpeechRecognitionService
    private let audioCaptureService: AudioCaptureService
    private let mlxWhisperProvider: MLXWhisperProvider
    private let mlxParakeetProvider: MLXParakeetProvider
    private let settingsReader: any VoiceSettingsReading
    private let startupOperation: StartupOperation?

    var isRecording: Bool { recordingState.isRecording }

    init(
        permissionManager: AudioPermissionManager,
        speechRecognitionService: SpeechRecognitionService,
        audioCaptureService: AudioCaptureService,
        mlxWhisperProvider: MLXWhisperProvider,
        mlxParakeetProvider: MLXParakeetProvider,
        settingsReader: any VoiceSettingsReading,
        startupOperation: StartupOperation?
    ) {
        self.permissionManager = permissionManager
        self.speechRecognitionService = speechRecognitionService
        self.audioCaptureService = audioCaptureService
        self.mlxWhisperProvider = mlxWhisperProvider
        self.mlxParakeetProvider = mlxParakeetProvider
        self.settingsReader = settingsReader
        self.startupOperation = startupOperation
        super.init()
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Permission status
        permissionManager.$permissionStatus
            .assign(to: &$permissionStatus)

        // Speech recognition
        speechRecognitionService.$transcribedText
            .assign(to: &$transcribedText)

        speechRecognitionService.$partialTranscription
            .assign(to: &$partialTranscription)

        // Audio capture
        audioCaptureService.$audioLevel
            .assign(to: &$audioLevel)

        audioCaptureService.$recordingDuration
            .assign(to: &$recordingDuration)
    }

    // MARK: - Permission Handling

    func requestPermissions(includeSpeech: Bool) async -> Bool {
        return await permissionManager.requestPermissions(includeSpeech: includeSpeech)
    }

    func checkPermissions(includeSpeech: Bool) -> Bool {
        permissionManager.checkPermissions(includeSpeech: includeSpeech)
    }

    // MARK: - Recording Control

    func startRecording(
        operationID: UUID,
        lifecycleState: @escaping @MainActor () -> AudioCaptureLifecycleState
    ) async throws {
        try Task.checkCancellation()
        let settings = settingsReader.currentSettings
        let requestedProvider = settings.provider
        let effectiveProvider = resolveProvider(for: settings)
        if requestedProvider == .mlxWhisper && effectiveProvider == .system {
            logger.warning("MLX Whisper not available; falling back to Apple Speech")
        } else if requestedProvider == .mlxParakeet && effectiveProvider == .system {
            logger.warning("MLX Parakeet not available; falling back to Apple Speech")
        }
        recordingState = .starting(operationID: operationID, provider: effectiveProvider)

        let needsSpeech = effectiveProvider == .system
        do {
            if let startupOperation {
                try await startupOperation(operationID, lifecycleState)
            } else {
                try await Self.runStartupSequence(
                    lifecycleState: lifecycleState,
                    operationIsCurrent: { [weak self] in
                        self?.recordingState.operationID == operationID
                    },
                    checkPermissions: { [weak self] in
                        self?.checkPermissions(includeSpeech: needsSpeech) ?? false
                    },
                    requestPermissions: { [weak self] in
                        await self?.requestPermissions(includeSpeech: needsSpeech) ?? false
                    },
                    startServices: { [weak self] in
                        guard let self else { throw CancellationError() }

                        self.speechRecognitionService.resetTranscriptions()
                        self.audioCaptureService.cancel()

                        switch effectiveProvider {
                        case .system:
                            try self.startAppleSpeech(lifecycleState: lifecycleState)
                        case .mlxWhisper, .mlxParakeet:
                            try self.startMLXCapture(lifecycleState: lifecycleState)
                        }
                    }
                )
            }

            guard recordingState.operationID == operationID else {
                throw CancellationError()
            }
            recordingState = .recording(operationID: operationID, provider: effectiveProvider)
        } catch {
            guard recordingState.operationID == operationID else {
                throw CancellationError()
            }
            recordingState = .idle
            audioCaptureService.cancel()
            speechRecognitionService.cancelRecognition()
            if error is CancellationError {
                throw error
            }
            throw recordingError(for: error)
        }
    }

    func stopRecording(operationID: UUID) async -> String {
        guard case .recording(let currentOperationID, let provider) = recordingState,
              currentOperationID == operationID else { return "" }
        recordingState = .processing(operationID: operationID, provider: provider)

        let samples = audioCaptureService.stop()

        switch provider {
        case .system:
            let finalText = await speechRecognitionService.stopRecognition()
            guard finishProcessing(operationID) else { return "" }
            speechRecognitionService.resetTranscriptions()
            return finalText
        case .mlxWhisper, .mlxParakeet:
            let settings = settingsReader.currentSettings
            let text = await Self.runProcessingSequence(
                operationIsCurrent: { [weak self] in
                    self?.processingIsCurrent(operationID) == true
                },
                transcribe: { [mlxWhisperProvider, mlxParakeetProvider] in
                    switch provider {
                    case .mlxWhisper:
                        return try await mlxWhisperProvider.transcribe(
                            samples: samples,
                            modelID: settings.whisperModelID,
                            languageCode: settings.languageCode
                        )
                    case .mlxParakeet:
                        return try await mlxParakeetProvider.transcribe(
                            samples: samples,
                            modelID: settings.parakeetModelID
                        )
                    case .system:
                        return ""
                    }
                },
                fallback: { [weak self] error in
                    guard let self else { return nil }
                    self.logger.error("\(provider.displayName) failed: \(error.localizedDescription)")
                    return await self.fallbackToAppleSpeech(
                        samples: samples,
                        operationID: operationID
                    )
                }
            )
            guard let text, finishProcessing(operationID) else {
                cancelProcessingIfCurrent(operationID)
                return ""
            }
            transcribedText = text
            return text
        }
    }

    func cancelRecording() {
        recordingState = .idle

        audioCaptureService.cancel()
        speechRecognitionService.cancelRecognition()
        speechRecognitionService.resetTranscriptions()
        transcribedText = ""
        partialTranscription = ""
    }

    static func runStartupSequence(
        lifecycleState: @escaping @MainActor () -> AudioCaptureLifecycleState,
        operationIsCurrent: @escaping @MainActor () -> Bool,
        checkPermissions: @escaping @MainActor () -> Bool,
        requestPermissions: @escaping @MainActor () async -> Bool,
        startServices: @escaping @MainActor () throws -> Void
    ) async throws {
        try validateStartup(
            lifecycleState: lifecycleState,
            operationIsCurrent: operationIsCurrent
        )

        let hasPermissions = checkPermissions()
        try validateStartup(
            lifecycleState: lifecycleState,
            operationIsCurrent: operationIsCurrent
        )
        if !hasPermissions {
            let granted = await requestPermissions()
            try validateStartup(
                lifecycleState: lifecycleState,
                operationIsCurrent: operationIsCurrent
            )
            guard granted else { throw RecordingError.permissionDenied }
        }

        try validateStartup(
            lifecycleState: lifecycleState,
            operationIsCurrent: operationIsCurrent
        )
        try startServices()
        try validateStartup(
            lifecycleState: lifecycleState,
            operationIsCurrent: operationIsCurrent
        )
    }

    static func runProcessingSequence(
        operationIsCurrent: @escaping @MainActor () -> Bool,
        transcribe: @escaping @MainActor () async throws -> String,
        fallback: @escaping @MainActor (Error) async -> String?
    ) async -> String? {
        do {
            let text = try await transcribe()
            guard operationIsCurrent(), !Task.isCancelled else { return nil }
            return text
        } catch {
            guard operationIsCurrent(), !Task.isCancelled else { return nil }
            let fallbackText = await fallback(error)
            guard operationIsCurrent(), !Task.isCancelled else { return nil }
            return fallbackText
        }
    }

    private static func validateStartup(
        lifecycleState: @MainActor () -> AudioCaptureLifecycleState,
        operationIsCurrent: @MainActor () -> Bool
    ) throws {
        try Task.checkCancellation()
        guard operationIsCurrent() else { throw CancellationError() }
        guard lifecycleState().allowsCapture else {
            throw RecordingError.inactiveLifecycle
        }
    }

    // MARK: - Errors

    enum RecordingError: LocalizedError {
        case permissionDenied
        case speechRecognitionUnavailable
        case recordingFailed
        case inactiveLifecycle
        case inputUnavailable
        case mlxUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "Microphone permission is required. The microphone will be automatically requested when recording starts.")
            case .speechRecognitionUnavailable:
                return String(localized: "Speech recognition is not available. Please enable Siri in System Settings > Siri & Spotlight.")
            case .recordingFailed:
                return String(localized: "Failed to start recording. Please check microphone permissions in System Settings > Privacy & Security > Microphone.")
            case .inactiveLifecycle:
                return String(localized: "Voice recording is only available while VVTerm is active.")
            case .inputUnavailable:
                return String(localized: "Audio input is temporarily unavailable. Please check the current microphone or audio route and try again.")
            case .mlxUnavailable:
                return MLXAudioSupport.unavailableDescription
            }
        }
    }

    // MARK: - Provider Resolution

    private func resolveProvider(for settings: VoiceSettings) -> TranscriptionProvider {
        switch settings.provider {
        case .system:
            return .system
        case .mlxWhisper:
            return TranscriptionProviderResolutionPolicy.resolve(
                requested: settings.provider,
                mlxSupported: MLXWhisperProvider.isSupported,
                requestedModelAvailable: MLXModelManager.isModelAvailable(
                    kind: .whisper,
                    modelId: settings.whisperModelID
                )
            )
        case .mlxParakeet:
            return TranscriptionProviderResolutionPolicy.resolve(
                requested: settings.provider,
                mlxSupported: MLXParakeetProvider.isSupported,
                requestedModelAvailable: MLXModelManager.isModelAvailable(
                    kind: .parakeetTDT,
                    modelId: settings.parakeetModelID
                )
            )
        }
    }

    // MARK: - Apple Speech

    private func startAppleSpeech(lifecycleState: () -> AudioCaptureLifecycleState) throws {
        guard speechRecognitionService.isAvailable else {
            throw RecordingError.speechRecognitionUnavailable
        }

        audioCaptureService.bufferHandler = { [weak speechRecognitionService] buffer in
            speechRecognitionService?.appendAudioBuffer(buffer)
        }

        try speechRecognitionService.startRecognition()
        guard lifecycleState().allowsCapture else {
            throw RecordingError.inactiveLifecycle
        }
        try audioCaptureService.start(lifecycleState: lifecycleState)
    }

    // MARK: - MLX

    private func startMLXCapture(lifecycleState: () -> AudioCaptureLifecycleState) throws {
        audioCaptureService.bufferHandler = nil
        try audioCaptureService.start(lifecycleState: lifecycleState)
    }

    private func recordingError(for error: Error) -> RecordingError {
        if let recordingError = error as? RecordingError {
            return recordingError
        }
        guard let captureError = error as? AudioCaptureService.RecordingError else {
            return .recordingFailed
        }
        switch captureError {
        case .inactiveLifecycle:
            return .inactiveLifecycle
        case .inputUnavailable:
            return .inputUnavailable
        case .converterUnavailable:
            return .recordingFailed
        }
    }

    private func processingIsCurrent(_ operationID: UUID) -> Bool {
        guard case .processing(let currentID, _) = recordingState else { return false }
        return currentID == operationID
    }

    private func finishProcessing(_ operationID: UUID) -> Bool {
        guard processingIsCurrent(operationID), !Task.isCancelled else {
            cancelProcessingIfCurrent(operationID)
            return false
        }
        recordingState = .idle
        return true
    }

    private func cancelProcessingIfCurrent(_ operationID: UUID) {
        if processingIsCurrent(operationID) {
            recordingState = .idle
        }
    }

    private func fallbackToAppleSpeech(
        samples: [Float],
        operationID: UUID
    ) async -> String? {
        guard !samples.isEmpty else { return nil }
        guard speechRecognitionService.isAvailable else { return nil }
        guard processingIsCurrent(operationID), !Task.isCancelled else { return nil }

        let hasPermissions = checkPermissions(includeSpeech: true)
        if !hasPermissions {
            let granted = await requestPermissions(includeSpeech: true)
            guard granted else { return nil }
            guard processingIsCurrent(operationID), !Task.isCancelled else { return nil }
        }

        do {
            guard processingIsCurrent(operationID), !Task.isCancelled else { return nil }
            let text = try await speechRecognitionService.transcribe(
                samples: samples,
                sampleRate: audioCaptureService.sampleRate
            )
            guard processingIsCurrent(operationID), !Task.isCancelled else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Apple Speech fallback failed: \(error.localizedDescription)")
            return nil
        }
    }
}
