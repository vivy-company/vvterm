import Foundation

final class MLXWhisperProvider {
    static var isSupported: Bool {
        MLXAudioSupport.isSupported
    }

    init() {}

    func transcribe(
        samples: [Float],
        modelID: String,
        languageCode: String
    ) async throws -> String {
        #if arch(arm64)
        let modelDirectory = await MainActor.run {
            MLXModelManager.modelDirectory(for: .whisper, modelId: modelID)
        }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard !samples.isEmpty else { return "" }

            return try WhisperModelLoader.shared.transcribe(
                samples: samples,
                modelDirectory: modelDirectory,
                modelID: modelID,
                languageCode: languageCode
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        #else
        throw NSError(domain: "MLXWhisper", code: -1, userInfo: [NSLocalizedDescriptionKey: "MLX Whisper not supported on this architecture"])
        #endif
    }

    #if arch(arm64)
    nonisolated fileprivate static func transcribe(
        samples: [Float],
        model: WhisperModel,
        modelID: String,
        languageCode: String
    ) throws -> String {
        try Task.checkCancellation()
        let mel = try WhisperAudioProcessor.logMelSpectrogram(
            samples,
            nMels: model.dims.n_mels,
            padding: WhisperAudioConstants.nSamples
        )
        let melSegment = WhisperAudioProcessor.padOrTrim(
            mel,
            length: WhisperAudioConstants.nFrames,
            axis: 0
        ).asType(.float16)
        let melBatch = melSegment.reshaped(1, melSegment.dim(0), melSegment.dim(1))

        let audioFeatures = model.encoder(melBatch)
        try Task.checkCancellation()

        let language: String?
        if model.isMultilingual {
            language = requestedLanguage(for: languageCode)
                ?? detectLanguage(model: model, audioFeatures: audioFeatures, modelId: modelID)
                ?? "en"
        } else {
            language = nil
        }

        let tokenizer = try WhisperTokenizer(
            multilingual: model.isMultilingual,
            language: language,
            task: "transcribe",
            modelId: modelID
        )

        let promptTokens = tokenizer.initialTokens(withoutTimestamps: true)
        var allTokens = promptTokens

        let promptArray = MLXArray(promptTokens, [1, promptTokens.count])
        var (logits, kvCache) = model.decoder(
            promptArray,
            audioFeatures: audioFeatures,
            kvCache: nil
        )
        var nextToken = try argmaxToken(from: logits)
        allTokens.append(nextToken)

        let maxTokens = model.dims.n_text_ctx
        while allTokens.count < maxTokens {
            try Task.checkCancellation()
            if nextToken == tokenizer.eot { break }
            let tokenArray = MLXArray([nextToken], [1, 1])
            let result = model.decoder(
                tokenArray,
                audioFeatures: audioFeatures,
                kvCache: kvCache
            )
            logits = result.0
            kvCache = result.1
            nextToken = try argmaxToken(from: logits)
            allTokens.append(nextToken)
        }

        let outputTokens = Array(allTokens.dropFirst(promptTokens.count))
        return tokenizer.decode(outputTokens).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    nonisolated private static func requestedLanguage(for languageCode: String) -> String? {
        guard languageCode != TranscriptionSettingsDefaults.autoLanguageCode else { return nil }
        return WhisperTokenizer.supportedLanguages.contains(languageCode) ? languageCode : nil
    }

    #if arch(arm64)
    nonisolated private static func argmaxToken(from logits: MLXArray) throws -> Int {
        let lastIndex = logits.dim(1) - 1
        let lastLogits = logits[0, lastIndex]
        let tokenArray = argMax(lastLogits, axis: -1)
        return tokenArray.item(Int.self)
    }

    /// Whisper language identification: decode one step from `<|startoftranscript|>` and
    /// pick the highest-scoring language token.
    nonisolated private static func detectLanguage(model: WhisperModel, audioFeatures: MLXArray, modelId: String) -> String? {
        guard let tokenizer = try? WhisperTokenizer(
            multilingual: true,
            language: nil,
            task: nil,
            modelId: modelId
        ) else { return nil }

        let sot = tokenizer.sot
        let languageCount = min(tokenizer.numLanguages, WhisperTokenizer.supportedLanguages.count)
        guard languageCount > 0 else { return nil }

        let promptArray = MLXArray([sot], [1, 1])
        let (logits, _) = model.decoder(promptArray, audioFeatures: audioFeatures, kvCache: nil)
        let lastLogits = logits[0, logits.dim(1) - 1]
        let languageLogits = lastLogits[(sot + 1) ..< (sot + 1 + languageCount)]
        let index = argMax(languageLogits, axis: -1).item(Int.self)
        guard index >= 0, index < languageCount else { return nil }
        return WhisperTokenizer.supportedLanguages[index]
    }
    #endif
}

#if arch(arm64)
import MLX
import MLXNN

/// MLX model loading and inference are serialized by `lock`. No model value
/// escapes this object, so the lock is the complete mutable-state boundary.
nonisolated final class WhisperModelLoader: @unchecked Sendable {
    static let shared = WhisperModelLoader()

    private var cachedModel: WhisperModel?
    private var cachedModelURL: URL?
    private let lock = NSLock()

    private init() {}

    func transcribe(
        samples: [Float],
        modelDirectory: URL,
        modelID: String,
        languageCode: String
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let model = try loadModel(at: modelDirectory)
        return try MLXWhisperProvider.transcribe(
            samples: samples,
            model: model,
            modelID: modelID,
            languageCode: languageCode
        )
    }

    private func loadModel(at modelDirectory: URL) throws -> WhisperModel {
        if let cachedModel, cachedModelURL == modelDirectory {
            return cachedModel
        }

        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(WhisperModelDimensions.self, from: configData)
        try MLXModelConfigurationValidator.validateWhisper(config)

        let weightURLs = Self.weightFileURLs(in: modelDirectory)
        guard !weightURLs.isEmpty else {
            throw NSError(domain: "MLXWhisper", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing model weights"])
        }

        let safetensors = weightURLs.filter { $0.pathExtension.lowercased() == "safetensors" }
        let npz = weightURLs.filter { $0.pathExtension.lowercased() == "npz" }

        var weights: [String: MLXArray] = [:]
        if !safetensors.isEmpty {
            for url in safetensors {
                let arrays = try loadArrays(url: url)
                weights.merge(arrays) { _, new in new }
            }
        } else if let npzURL = npz.first {
            let arrays = try NPZLoader.loadArrays(from: npzURL)
            weights.merge(arrays) { _, new in new }
        }
        let model = try WhisperModel(dims: config, dtype: .float16)

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

    private enum WeightNode {
        case value(MLXArray)
        case dictionary([String: WeightNode])
    }

    private static func nestedDictionary(from flat: [String: MLXArray]) -> NestedDictionary<String, MLXArray> {
        var root: [String: WeightNode] = [:]

        for (key, value) in flat {
            var parts = key.split(separator: ".").map(String.init)
            if parts.first == "model" {
                parts.removeFirst()
            }
            guard !parts.isEmpty else { continue }
            insert(value: value, parts: parts[...], into: &root)
        }

        var converted: [String: NestedItem<String, MLXArray>] = [:]
        for (key, node) in root {
            converted[key] = toNestedItem(node)
        }
        return NestedDictionary(values: converted)
    }

    private static func insert(
        value: MLXArray,
        parts: ArraySlice<String>,
        into dict: inout [String: WeightNode]
    ) {
        guard let head = parts.first else { return }
        let remaining = parts.dropFirst()
        if remaining.isEmpty {
            dict[head] = .value(value)
            return
        }

        var child: [String: WeightNode]
        if case .dictionary(let existing)? = dict[head] {
            child = existing
        } else {
            child = [:]
        }
        insert(value: value, parts: remaining, into: &child)
        dict[head] = .dictionary(child)
    }

    private static func toNestedItem(_ node: WeightNode) -> NestedItem<String, MLXArray> {
        switch node {
        case .value(let value):
            return .value(value)
        case .dictionary(let dict):
            if let arrayItems = numericArray(from: dict) {
                return .array(arrayItems)
            }

            var converted: [String: NestedItem<String, MLXArray>] = [:]
            for (key, child) in dict {
                converted[key] = toNestedItem(child)
            }
            return .dictionary(converted)
        }
    }

    private static func numericArray(from dict: [String: WeightNode]) -> [NestedItem<String, MLXArray>]? {
        guard !dict.isEmpty else { return nil }
        let indices = dict.keys.compactMap { Int($0) }
        guard indices.count == dict.count else { return nil }
        guard let minIndex = indices.min(), let maxIndex = indices.max() else { return nil }
        guard minIndex == 0 && maxIndex == dict.count - 1 else { return nil }

        var items = Array(repeating: NestedItem<String, MLXArray>.dictionary([:]), count: maxIndex + 1)
        for (key, node) in dict {
            guard let index = Int(key) else { continue }
            items[index] = toNestedItem(node)
        }
        return items
    }
}
#endif
