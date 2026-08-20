import Foundation
import Combine
import Speech
import AVFoundation

nonisolated enum SpeechRecognitionOperationState: Equatable, Sendable {
    case idle
    case running(UUID)
    case finishing(UUID)

    var generation: UUID? {
        switch self {
        case .idle:
            return nil
        case .running(let generation), .finishing(let generation):
            return generation
        }
    }

    func acceptsResult(for generation: UUID) -> Bool {
        self.generation == generation
    }
}

nonisolated final class SpeechRecognitionResultState: @unchecked Sendable {
    private let lock = NSLock()
    private let temporaryFileURL: URL?
    private var resolution: Result<String, any Error>?
    private var continuation: CheckedContinuation<String, any Error>?

    init(temporaryFileURL: URL? = nil) {
        self.temporaryFileURL = temporaryFileURL
    }

    func value() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let resolution {
                lock.unlock()
                continuation.resume(with: resolution)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func resolve(_ resolution: Result<String, any Error>) -> Bool {
        lock.lock()
        guard self.resolution == nil else {
            lock.unlock()
            return false
        }
        self.resolution = resolution
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let temporaryFileURL {
            try? FileManager.default.removeItem(at: temporaryFileURL)
        }
        continuation?.resume(with: resolution)
        return true
    }
}

@MainActor
class SpeechRecognitionService: ObservableObject {
    @Published var transcribedText = ""
    @Published var partialTranscription = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognizerLanguageCode: String?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionState: SpeechRecognitionOperationState = .idle
    private var recognitionCompletionStream: AsyncStream<Void>?
    private var recognitionCompletionContinuation: AsyncStream<Void>.Continuation?
    private var transcriptionResultState: SpeechRecognitionResultState?
    private let selectedLanguageCode: @MainActor () -> String

    init(selectedLanguageCode: @escaping @MainActor () -> String) {
        self.selectedLanguageCode = selectedLanguageCode
    }

    var isAvailable: Bool {
        resolvedRecognizer()?.isAvailable ?? false
    }

    // MARK: - Recognizer Resolution

    private static let preferredLocaleIdentifiers: [String: String] = [
        "en": "en-US",
        "es": "es-ES",
        "fr": "fr-FR",
        "de": "de-DE",
        "ja": "ja-JP",
        "zh": "zh-CN",
        "ko": "ko-KR",
        "pt": "pt-BR",
        "ru": "ru-RU"
    ]

    private func resolvedRecognizer() -> SFSpeechRecognizer? {
        let languageCode = selectedLanguageCode()
        if let speechRecognizer, recognizerLanguageCode == languageCode {
            return speechRecognizer
        }
        let recognizer = Self.makeRecognizer(languageCode: languageCode)
        speechRecognizer = recognizer
        recognizerLanguageCode = languageCode
        return recognizer
    }

    private static func makeRecognizer(languageCode: String) -> SFSpeechRecognizer? {
        for locale in candidateLocales(languageCode: languageCode) {
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    private static func candidateLocales(languageCode: String) -> [Locale] {
        guard languageCode != TranscriptionSettingsDefaults.autoLanguageCode else {
            return [Locale.current]
        }

        var identifiers: [String] = []
        if let preferred = preferredLocaleIdentifiers[languageCode] {
            identifiers.append(preferred)
        }
        let supportedMatches = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode?.identifier == languageCode }
            .map(\.identifier)
            .sorted()
        identifiers.append(contentsOf: supportedMatches)
        identifiers.append(languageCode)

        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted else { return nil }
            return Locale(identifier: identifier)
        }
    }

    // MARK: - Recognition Control

    func startRecognition() throws {
        guard let speechRecognizer = resolvedRecognizer(), speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        cancelBatchTranscription()
        recognitionTask?.cancel()
        recognitionTask = nil
        finishRecognitionCompletion()

        let generation = UUID()
        recognitionState = .running(generation)
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        recognitionCompletionStream = completion.stream
        recognitionCompletionContinuation = completion.continuation

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = recognitionRequest
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            let transcription = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let didComplete = error != nil || isFinal
            guard transcription != nil || didComplete else { return }

            Task { @MainActor [weak self, completionContinuation = completion.continuation] in
                guard let self, self.recognitionState.acceptsResult(for: generation) else { return }
                if let transcription {
                    if isFinal {
                        self.transcribedText = transcription
                    } else {
                        self.partialTranscription = transcription
                    }
                }
                if didComplete {
                    completionContinuation.yield()
                    completionContinuation.finish()
                }
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopRecognition() async -> String {
        if transcriptionResultState != nil {
            cancelRecognition()
            return ""
        }

        guard let generation = recognitionState.generation else {
            return transcribedText.isEmpty ? partialTranscription : transcribedText
        }
        recognitionState = .finishing(generation)
        let completionStream = recognitionCompletionStream
        recognitionRequest?.endAudio()
        recognitionTask?.finish()

        if let completionStream {
            await Self.waitForRecognitionCompletion(
                completionStream,
                timeout: .milliseconds(500)
            )
        }

        guard recognitionState == .finishing(generation) else { return "" }
        guard !Task.isCancelled else {
            cancelRecognition()
            return ""
        }
        let finalText = transcribedText.isEmpty ? partialTranscription : transcribedText
        recognitionState = .idle
        recognitionRequest = nil
        recognitionTask = nil
        finishRecognitionCompletion()
        return finalText
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard Self.acceptsAudioInput(sampleCount: samples.count, sampleRate: sampleRate) else {
            throw SpeechRecognitionError.invalidAudio
        }
        guard let speechRecognizer = resolvedRecognizer(), speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        cancelBatchTranscription()
        recognitionTask?.cancel()
        recognitionTask = nil
        finishRecognitionCompletion()
        let generation = UUID()
        recognitionState = .running(generation)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-transcription-\(UUID().uuidString)")
            .appendingPathExtension("caf")

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?.pointee else {
            throw SpeechRecognitionError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }

        do {
            let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            recognitionState = .idle
            throw error
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false
        let resultState = SpeechRecognitionResultState(temporaryFileURL: tempURL)
        transcriptionResultState = resultState

        defer {
            if recognitionState.acceptsResult(for: generation) {
                recognitionTask?.cancel()
                recognitionTask = nil
                recognitionState = .idle
            }
            if transcriptionResultState === resultState {
                transcriptionResultState = nil
            }
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resultState.resolve(.failure(error))
                    return
                }

                guard let result, result.isFinal else { return }
                resultState.resolve(.success(result.bestTranscription.formattedString))
            }
            let result = try await resultState.value()
            try Task.checkCancellation()
            return result
        } onCancel: {
            resultState.resolve(.failure(CancellationError()))
        }
    }

    func cancelRecognition() {
        recognitionState = .idle
        recognitionRequest?.endAudio()
        cancelBatchTranscription()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        finishRecognitionCompletion()

        transcribedText = ""
        partialTranscription = ""
    }

    func resetTranscriptions() {
        transcribedText = ""
        partialTranscription = ""
    }

    nonisolated static func waitForRecognitionCompletion(
        _ stream: AsyncStream<Void>,
        timeout: Duration
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { break }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    nonisolated static func acceptsAudioInput(sampleCount: Int, sampleRate: Double) -> Bool {
        sampleCount > 0
            && sampleCount <= Int(AVAudioFrameCount.max)
            && sampleRate.isFinite
            && sampleRate > 0
    }

    private func finishRecognitionCompletion() {
        recognitionCompletionContinuation?.finish()
        recognitionCompletionContinuation = nil
        recognitionCompletionStream = nil
    }

    private func cancelBatchTranscription() {
        transcriptionResultState?.resolve(.failure(CancellationError()))
        transcriptionResultState = nil
    }

    // MARK: - Errors

    enum SpeechRecognitionError: LocalizedError {
        case recognitionUnavailable
        case invalidAudio

        var errorDescription: String? {
            switch self {
            case .recognitionUnavailable:
                return "Speech recognition is not available. Please enable Siri in System Settings > Siri & Spotlight."
            case .invalidAudio:
                return "The audio data is invalid."
            }
        }
    }
}
