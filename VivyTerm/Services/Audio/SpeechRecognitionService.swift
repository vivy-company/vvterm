import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
class SpeechRecognitionService: ObservableObject {
    @Published var transcribedText = ""
    @Published var partialTranscription = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    var isAvailable: Bool {
        speechRecognizer?.isAvailable ?? false
    }

    // MARK: - Recognition Control

    func startRecognition() async throws {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = recognitionRequest
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString

                Task { @MainActor in
                    if result.isFinal {
                        self.transcribedText = transcription
                    } else {
                        self.partialTranscription = transcription
                    }
                }
            }

            if error != nil || result?.isFinal == true {
                // No audio engine to stop here; AudioCaptureService handles input
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopRecognition() async -> String {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        // Wait for final transcription
        try? await Task.sleep(for: .milliseconds(500))

        let finalText = transcribedText.isEmpty ? partialTranscription : transcribedText
        return finalText
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivyterm-transcription-\(UUID().uuidString)")
            .appendingPathExtension("caf")

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channel = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { ptr in
                channel.assign(from: ptr.baseAddress!, count: samples.count)
            }
        }

        try file.write(from: buffer)

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let cleanup: () -> Void = {
                try? FileManager.default.removeItem(at: tempURL)
            }

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                if finished { return }

                if let error {
                    finished = true
                    cleanup()
                    Task { @MainActor in
                        self?.recognitionTask = nil
                    }
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else { return }
                if result.isFinal {
                    finished = true
                    cleanup()
                    Task { @MainActor in
                        self?.recognitionTask = nil
                    }
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    func cancelRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        transcribedText = ""
        partialTranscription = ""
    }

    func resetTranscriptions() {
        transcribedText = ""
        partialTranscription = ""
    }

    // MARK: - Errors

    enum SpeechRecognitionError: LocalizedError {
        case recognitionUnavailable

        var errorDescription: String? {
            switch self {
            case .recognitionUnavailable:
                return "Speech recognition is not available. Please enable Siri in System Settings > Siri & Spotlight."
            }
        }
    }
}
