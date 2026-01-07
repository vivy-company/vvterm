import Foundation

final class MLXParakeetProvider {
    static let shared = MLXParakeetProvider()

    static var isSupported: Bool {
        MLXAudioSupport.isSupported
    }

    private init() {}

    func transcribe(samples: [Float]) async throws -> String {
        #if arch(arm64)
        let modelId = TranscriptionSettingsStore.currentParakeetModelId()
        let modelDirectory = await MainActor.run {
            MLXModelManager.modelDirectory(for: .parakeetTDT, modelId: modelId)
        }

        return try await Task.detached(priority: .userInitiated) {
            guard !samples.isEmpty else { return "" }

            let model = try ParakeetModelLoader.shared.loadModel(at: modelDirectory)
            let audio = MLXArray(samples, [samples.count])
            let result = try model.transcribe(audioData: audio, dtype: .float32, chunkDuration: nil)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        #else
        throw NSError(domain: "MLXParakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "MLX Parakeet not supported on this architecture"])
        #endif
    }
}

#if arch(arm64)
import MLX
@preconcurrency import MLXNN

nonisolated final class ParakeetModelLoader {
    static let shared = ParakeetModelLoader()

    private var cachedModel: ParakeetTDT?
    private var cachedModelURL: URL?
    private let lock = NSLock()

    private init() {}

    func loadModel(at modelDirectory: URL) throws -> ParakeetTDT {
        lock.lock()
        defer { lock.unlock() }

        if let cachedModel, cachedModelURL == modelDirectory {
            return cachedModel
        }

        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(ParakeetTDTConfig.self, from: configData)

        let weightURLs = Self.weightFileURLs(in: modelDirectory)
        guard !weightURLs.isEmpty else {
            throw NSError(domain: "MLXParakeet", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing model weights"])
        }

        let model = try ParakeetTDT(config: config)
        try model.loadWeights(from: weightURLs)
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
