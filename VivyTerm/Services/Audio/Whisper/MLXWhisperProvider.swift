import Foundation

final class MLXWhisperProvider {
    static let shared = MLXWhisperProvider()

    static var isSupported: Bool {
        MLXAudioSupport.isSupported
    }

    private init() {}

    func transcribe(samples: [Float]) async throws -> String {
        #if arch(arm64)
        let modelId = TranscriptionSettingsStore.currentWhisperModelId()
        let modelDirectory = await MainActor.run {
            MLXModelManager.modelDirectory(for: .whisper, modelId: modelId)
        }
        return try await Task.detached(priority: .userInitiated) {
            guard !samples.isEmpty else { return "" }

            let model = try WhisperModelLoader.shared.loadModel(at: modelDirectory)
            let tokenizer = try WhisperTokenizer(multilingual: model.isMultilingual, language: "en", task: "transcribe")

            let mel = try WhisperAudioProcessor.logMelSpectrogram(samples, nMels: model.dims.n_mels, padding: WhisperAudioConstants.nSamples)
            let melSegment = WhisperAudioProcessor.padOrTrim(mel, length: WhisperAudioConstants.nFrames, axis: 0).asType(.float16)
            let melBatch = melSegment.reshaped(1, melSegment.dim(0), melSegment.dim(1))

            let audioFeatures = model.encoder(melBatch)

            let promptTokens = tokenizer.initialTokens(withoutTimestamps: true)
            var allTokens = promptTokens

            let promptArray = MLXArray(promptTokens, [1, promptTokens.count])
            var (logits, kvCache) = model.decoder(promptArray, audioFeatures: audioFeatures, kvCache: nil)
            var nextToken = try Self.argmaxToken(from: logits)
            allTokens.append(nextToken)

            let maxTokens = model.dims.n_text_ctx
            while allTokens.count < maxTokens {
                if nextToken == tokenizer.eot { break }
                let tokenArray = MLXArray([nextToken], [1, 1])
                let result = model.decoder(tokenArray, audioFeatures: audioFeatures, kvCache: kvCache)
                logits = result.0
                kvCache = result.1
                nextToken = try Self.argmaxToken(from: logits)
                allTokens.append(nextToken)
            }

            let outputTokens = Array(allTokens.dropFirst(promptTokens.count))
            return tokenizer.decode(outputTokens).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        #else
        throw NSError(domain: "MLXWhisper", code: -1, userInfo: [NSLocalizedDescriptionKey: "MLX Whisper not supported on this architecture"])
        #endif
    }

    #if arch(arm64)
    nonisolated private static func argmaxToken(from logits: MLXArray) throws -> Int {
        let lastIndex = logits.dim(1) - 1
        let lastLogits = logits[0, lastIndex]
        let tokenArray = argMax(lastLogits, axis: -1)
        return tokenArray.item(Int.self)
    }
    #endif
}

#if arch(arm64)
import MLX
import MLXNN

nonisolated final class WhisperModelLoader {
    static let shared = WhisperModelLoader()

    private var cachedModel: WhisperModel?
    private var cachedModelURL: URL?
    private let lock = NSLock()

    private init() {}

    func loadModel(at modelDirectory: URL) throws -> WhisperModel {
        lock.lock()
        defer { lock.unlock() }

        if let cachedModel, cachedModelURL == modelDirectory {
            return cachedModel
        }

        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(WhisperModelDimensions.self, from: configData)

        let weightURLs = Self.weightFileURLs(in: modelDirectory)
        guard !weightURLs.isEmpty else {
            throw NSError(domain: "MLXWhisper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing model weights"])
        }

        var weights: [String: MLXArray] = [:]
        for url in weightURLs {
            let arrays = try loadArrays(url: url)
            weights.merge(arrays) { _, new in new }
        }
        let model = WhisperModel(dims: config, dtype: .float16)

        let nested = Self.nestedDictionary(from: weights)
        try model.update(parameters: nested, verify: .none)
        eval(model)

        cachedModel = model
        cachedModelURL = modelDirectory
        return model
    }

    private static func weightFileURLs(in directory: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let allowedExtensions = Set(["safetensors", "npz"])
        return files.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }

    private static func nestedDictionary(from flat: [String: MLXArray]) -> NestedDictionary<String, MLXArray> {
        var root: [String: NestedItem<String, MLXArray>] = [:]

        for (key, value) in flat {
            var parts = key.split(separator: ".").map(String.init)
            if parts.first == "model" {
                parts.removeFirst()
            }
            guard !parts.isEmpty else { continue }
            insert(value: value, parts: parts[...], into: &root)
        }

        return NestedDictionary(values: root)
    }

    private static func insert(
        value: MLXArray,
        parts: ArraySlice<String>,
        into dict: inout [String: NestedItem<String, MLXArray>]
    ) {
        guard let head = parts.first else { return }
        let remaining = parts.dropFirst()
        if remaining.isEmpty {
            dict[head] = .value(value)
            return
        }

        var child: [String: NestedItem<String, MLXArray>]
        if case .dictionary(let existing)? = dict[head] {
            child = existing
        } else {
            child = [:]
        }
        insert(value: value, parts: remaining, into: &child)
        dict[head] = .dictionary(child)
    }
}
#endif
