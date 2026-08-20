import Foundation

final class MLXParakeetProvider {
    static var isSupported: Bool {
        MLXAudioSupport.isSupported
    }

    init() {}

    func transcribe(samples: [Float], modelID: String) async throws -> String {
        #if arch(arm64)
        guard Self.isSupported else {
            throw NSError(
                domain: "MLXParakeet",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: MLXAudioSupport.unavailableDescription]
            )
        }
        let modelDirectory = await MainActor.run {
            MLXModelManager.modelDirectory(for: .parakeetTDT, modelId: modelID)
        }

        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard !samples.isEmpty else { return "" }

            let result = try ParakeetModelLoader.shared.transcribe(
                samples: samples,
                modelDirectory: modelDirectory
            )
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        #else
        throw NSError(
            domain: "MLXParakeet",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: MLXAudioSupport.unavailableDescription]
        )
        #endif
    }
}

#if arch(arm64)
import MLX
@preconcurrency import MLXNN

/// MLX model loading and inference are serialized by `lock`. No model value
/// escapes this object, so the lock is the complete mutable-state boundary.
nonisolated final class ParakeetModelLoader: @unchecked Sendable {
    static let shared = ParakeetModelLoader()

    private var cachedModel: ParakeetTDT?
    private var cachedModelURL: URL?
    private let lock = NSLock()

    private init() {}

    func transcribe(samples: [Float], modelDirectory: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try Task.checkCancellation()
        let model = try loadModel(at: modelDirectory)
        try Task.checkCancellation()
        let audio = MLXArray(samples, [samples.count])
        let result = try model.transcribe(audioData: audio, dtype: .float32, chunkDuration: nil)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadModel(at modelDirectory: URL) throws -> ParakeetTDT {
        if let cachedModel, cachedModelURL == modelDirectory {
            return cachedModel
        }

        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(ParakeetTDTConfig.self, from: configData)
        try MLXModelConfigurationValidator.validateParakeet(config)

        let weightURLs = Self.weightFileURLs(in: modelDirectory)
        guard !weightURLs.isEmpty else {
            throw NSError(domain: "MLXParakeet", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing model weights"])
        }

        let safetensors = weightURLs.filter { $0.pathExtension.lowercased() == "safetensors" }
        let npz = weightURLs.filter { $0.pathExtension.lowercased() == "npz" }

        let model = try ParakeetTDT(config: config)
        if !safetensors.isEmpty {
            try model.loadWeights(from: safetensors)
        } else if let npzURL = npz.first {
            let arrays = try NPZLoader.loadArrays(from: npzURL)
            try model.loadWeights(from: arrays)
        }
        model.train(false)
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
}
#endif
