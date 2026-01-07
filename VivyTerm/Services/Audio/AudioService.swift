import Foundation
import Combine
import os.log

@MainActor
class AudioService: NSObject, ObservableObject {
    private let logger = Logger.audio
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var partialTranscription = ""
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0
    @Published var permissionStatus: AudioPermissionManager.PermissionStatus = .notDetermined

    // Services
    private let permissionManager = AudioPermissionManager()
    private let speechRecognitionService = SpeechRecognitionService()
    private let audioCaptureService = AudioCaptureService()
    private let mlxWhisperProvider = MLXWhisperProvider.shared
    private let mlxParakeetProvider = MLXParakeetProvider.shared

    private var activeProvider: TranscriptionProvider = .system

    override init() {
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

    func checkPermissions(includeSpeech: Bool) async -> Bool {
        return await permissionManager.checkPermissions(includeSpeech: includeSpeech)
    }

    // MARK: - Recording Control

    func startRecording() async throws {
        let requestedProvider = TranscriptionSettingsStore.currentProvider()
        let effectiveProvider = resolveProvider(for: requestedProvider)
        if requestedProvider == .mlxWhisper && effectiveProvider == .system {
            logger.warning("MLX Whisper not available; falling back to Apple Speech")
        } else if requestedProvider == .mlxParakeet && effectiveProvider == .system {
            logger.warning("MLX Parakeet not available; falling back to Apple Speech")
        }
        activeProvider = effectiveProvider

        let needsSpeech = effectiveProvider == .system
        let hasPermissions = await checkPermissions(includeSpeech: needsSpeech)
        if !hasPermissions {
            let granted = await requestPermissions(includeSpeech: needsSpeech)
            guard granted else {
                throw RecordingError.permissionDenied
            }
        }

        // Reset state
        speechRecognitionService.resetTranscriptions()
        audioCaptureService.cancel()

        // Start services
        switch effectiveProvider {
        case .system:
            try await startAppleSpeech()
        case .mlxWhisper, .mlxParakeet:
            try startMLXCapture()
        }

        isRecording = true
    }

    func stopRecording() async -> String {
        isRecording = false

        let samples = audioCaptureService.stop()

        switch activeProvider {
        case .system:
            let finalText = await speechRecognitionService.stopRecognition()
            speechRecognitionService.resetTranscriptions()
            return finalText
        case .mlxWhisper:
            do {
                let text = try await mlxWhisperProvider.transcribe(samples: samples)
                transcribedText = text
                return text
            } catch {
                logger.error("MLX Whisper failed: \(error.localizedDescription)")
                if let fallback = await fallbackToAppleSpeech(samples: samples) {
                    transcribedText = fallback
                    return fallback
                }
                return ""
            }
        case .mlxParakeet:
            do {
                let text = try await mlxParakeetProvider.transcribe(samples: samples)
                transcribedText = text
                return text
            } catch {
                logger.error("MLX Parakeet failed: \(error.localizedDescription)")
                if let fallback = await fallbackToAppleSpeech(samples: samples) {
                    transcribedText = fallback
                    return fallback
                }
                return ""
            }
        }
    }

    func cancelRecording() {
        isRecording = false

        audioCaptureService.cancel()
        speechRecognitionService.cancelRecognition()
        speechRecognitionService.resetTranscriptions()
        transcribedText = ""
        partialTranscription = ""
    }

    // MARK: - Errors

    enum RecordingError: LocalizedError {
        case permissionDenied
        case speechRecognitionUnavailable
        case recordingFailed
        case mlxUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission is required. The microphone will be automatically requested when recording starts."
            case .speechRecognitionUnavailable:
                return "Speech recognition is not available. Please enable Siri in System Settings > Siri & Spotlight."
            case .recordingFailed:
                return "Failed to start recording. Please check microphone permissions in System Settings > Privacy & Security > Microphone."
            case .mlxUnavailable:
                return "MLX transcription is not available on this Mac. Switching to Apple Speech."
            }
        }
    }

    // MARK: - Provider Resolution

    private func resolveProvider(for requested: TranscriptionProvider) -> TranscriptionProvider {
        switch requested {
        case .system:
            return .system
        case .mlxWhisper:
            guard MLXWhisperProvider.isSupported else { return .system }
            let modelId = TranscriptionSettingsStore.currentWhisperModelId()
            guard MLXModelManager.isModelAvailable(kind: .whisper, modelId: modelId) else { return .system }
            return .mlxWhisper
        case .mlxParakeet:
            guard MLXParakeetProvider.isSupported else { return .system }
            let modelId = TranscriptionSettingsStore.currentParakeetModelId()
            guard MLXModelManager.isModelAvailable(kind: .parakeetTDT, modelId: modelId) else { return .system }
            return .mlxParakeet
        }
    }

    // MARK: - Apple Speech

    private func startAppleSpeech() async throws {
        guard speechRecognitionService.isAvailable else {
            throw RecordingError.speechRecognitionUnavailable
        }

        audioCaptureService.bufferHandler = { [weak speechRecognitionService] buffer in
            speechRecognitionService?.appendAudioBuffer(buffer)
        }

        try await speechRecognitionService.startRecognition()
        do {
            try audioCaptureService.start()
        } catch {
            throw RecordingError.recordingFailed
        }
    }

    // MARK: - MLX

    private func startMLXCapture() throws {
        audioCaptureService.bufferHandler = nil
        do {
            try audioCaptureService.start()
        } catch {
            throw RecordingError.recordingFailed
        }
    }

    private func fallbackToAppleSpeech(samples: [Float]) async -> String? {
        guard !samples.isEmpty else { return nil }
        guard speechRecognitionService.isAvailable else { return nil }

        let hasPermissions = await checkPermissions(includeSpeech: true)
        if !hasPermissions {
            let granted = await requestPermissions(includeSpeech: true)
            guard granted else { return nil }
        }

        do {
            let text = try await speechRecognitionService.transcribe(
                samples: samples,
                sampleRate: audioCaptureService.sampleRate
            )
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Apple Speech fallback failed: \(error.localizedDescription)")
            return nil
        }
    }
}
