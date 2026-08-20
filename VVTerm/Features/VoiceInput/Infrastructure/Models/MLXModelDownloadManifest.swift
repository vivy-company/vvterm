import CryptoKit
import Foundation

nonisolated struct MLXModelDownloadFile: Equatable, Sendable {
    let sourceURL: String
    let localFilename: String
    let expectedBytes: Int64
    let sha256: String
}

nonisolated struct MLXModelDownloadManifest: Equatable, Sendable {
    let modelID: String
    let revision: String
    let files: [MLXModelDownloadFile]

    var expectedBytes: Int64? {
        files.reduce(into: Optional<Int64>(0)) { total, file in
            guard let current = total else { return }
            let result = current.addingReportingOverflow(file.expectedBytes)
            total = result.overflow ? nil : result.partialValue
        }
    }

    static let markerFilename = ".vvterm-model-revision"
}

nonisolated enum MLXModelDownloadError: Error, Equatable, LocalizedError {
    case unsupportedModel
    case invalidManifest
    case fileCountLimitExceeded
    case fileSizeLimitExceeded
    case aggregateSizeLimitExceeded
    case repositoryQuotaExceeded
    case insufficientFreeSpace
    case unexpectedResponseSize
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return "This model does not have a trusted download manifest."
        case .invalidManifest:
            return "The model download manifest is invalid."
        case .fileCountLimitExceeded:
            return "The model contains too many files."
        case .fileSizeLimitExceeded:
            return "A model file exceeds the download limit."
        case .aggregateSizeLimitExceeded:
            return "The model exceeds the download limit."
        case .repositoryQuotaExceeded:
            return "Model storage is full. Remove another model and try again."
        case .insufficientFreeSpace:
            return "There is not enough free storage for this model."
        case .unexpectedResponseSize:
            return "A model file has an unexpected size."
        case .checksumMismatch:
            return "A model file failed integrity verification."
        }
    }
}

nonisolated enum MLXModelDownloadBudget {
    static let maximumFileCount = 8
    static let maximumFileBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumDownloadBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumRepositoryBytes: Int64 = 12 * 1_024 * 1_024 * 1_024
    static let requiredFreeSpaceReserve: Int64 = 512 * 1_024 * 1_024

    static func validate(
        manifest: MLXModelDownloadManifest,
        currentRepositoryBytes: Int64,
        availableCapacity: Int64
    ) throws -> Int64 {
        guard !manifest.revision.isEmpty,
              !manifest.files.isEmpty,
              currentRepositoryBytes >= 0,
              availableCapacity >= 0 else {
            throw MLXModelDownloadError.invalidManifest
        }
        guard manifest.files.count <= maximumFileCount else {
            throw MLXModelDownloadError.fileCountLimitExceeded
        }

        var filenames = Set<String>()
        for file in manifest.files {
            guard URL(string: file.sourceURL) != nil,
                  file.localFilename == (file.localFilename as NSString).lastPathComponent,
                  !file.localFilename.isEmpty,
                  file.expectedBytes > 0,
                  file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }),
                  filenames.insert(file.localFilename).inserted else {
                throw MLXModelDownloadError.invalidManifest
            }
            guard file.expectedBytes <= maximumFileBytes else {
                throw MLXModelDownloadError.fileSizeLimitExceeded
            }
        }
        guard let expectedBytes = manifest.expectedBytes else {
            throw MLXModelDownloadError.aggregateSizeLimitExceeded
        }
        guard expectedBytes <= maximumDownloadBytes else {
            throw MLXModelDownloadError.aggregateSizeLimitExceeded
        }

        let repositoryTotal = currentRepositoryBytes.addingReportingOverflow(expectedBytes)
        guard !repositoryTotal.overflow,
              repositoryTotal.partialValue <= maximumRepositoryBytes else {
            throw MLXModelDownloadError.repositoryQuotaExceeded
        }

        let requiredCapacity = expectedBytes.addingReportingOverflow(requiredFreeSpaceReserve)
        guard !requiredCapacity.overflow,
              availableCapacity >= requiredCapacity.partialValue else {
            throw MLXModelDownloadError.insufficientFreeSpace
        }
        return expectedBytes
    }
}

nonisolated enum MLXModelFileVerifier {
    static func verify(
        _ url: URL,
        expectedBytes: Int64,
        sha256 expectedSHA256: String
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              Int64(fileSize) == expectedBytes else {
            throw MLXModelDownloadError.unexpectedResponseSize
        }
        guard try sha256(of: url) == expectedSHA256.lowercased() else {
            throw MLXModelDownloadError.checksumMismatch
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension MLXModelCatalog {
    nonisolated static func downloadManifest(
        for modelID: String,
        kind: MLXModelKind
    ) -> MLXModelDownloadManifest? {
        switch (kind, modelID) {
        case (.whisper, "mlx-community/whisper-tiny-mlx"):
            return whisperManifest(
                modelID: modelID,
                revision: "6caf9c55601caafbe6508a8b0d216bdf4783c4e8",
                configBytes: 262,
                configSHA256: "aaff20ce8f69beddee3fe0cc1e08f4e92f58586cb9f12ba00a6f73cbfec1cb1c",
                weightFilename: "weights.npz",
                weightBytes: 74_418_540,
                weightSHA256: "0e03a5993d6eea43b07ee2dcc772b0e4cef5bb227257dacc24bf289387d49186"
            )
        case (.whisper, "mlx-community/whisper-tiny.en-mlx"):
            return whisperManifest(
                modelID: modelID,
                revision: "5f4dafbb28e62a53c1b10426ff7eed36ca733bf7",
                configBytes: 262,
                configSHA256: "452e616242261333a661bc86db762b3720d6cc7e2eccd3d8e19a631871c26dd9",
                weightFilename: "weights.npz",
                weightBytes: 74_417_804,
                weightSHA256: "4627203f0807d6496dda0d200e893b04ff24c98e73aa51c485c06203a0330b17"
            )
        case (.whisper, "mlx-community/whisper-base-mlx"):
            return whisperManifest(
                modelID: modelID,
                revision: "1e3e249fb8d01c655324bd6841b1deadffd6d04c",
                configBytes: 262,
                configSHA256: "737220a6d958b3ad48e78f840fa991556266983c84ea2ca40e413389c62e4c2f",
                weightFilename: "weights.npz",
                weightBytes: 143_724_204,
                weightSHA256: "2f57d5f3ef473054c638961f90716f4ee415e8108de81313eccb2c5fd62eff0b"
            )
        case (.whisper, "mlx-community/whisper-small-mlx"):
            return whisperManifest(
                modelID: modelID,
                revision: "45f3915923c7a79a5a5b5a7d909d39aeb0e5630e",
                configBytes: 266,
                configSHA256: "e8f58e638208af66d5d5d67801259dc7a12d199e971967a9f9d33a8e3635668e",
                weightFilename: "weights.npz",
                weightBytes: 481_307_592,
                weightSHA256: "55b6674c9b339702d486e2b1573839a66f8ec8f821ed2886993ef717a86b09f5"
            )
        case (.whisper, "mlx-community/whisper-medium-mlx"):
            return whisperManifest(
                modelID: modelID,
                revision: "7fc08c4eac4c316526498f147dfdee6f6303f975",
                configBytes: 268,
                configSHA256: "3ff0b3f17a5a3a614327ffd835a3c8f6c78f39cbd39e84dbff4b0ae267c4d2e4",
                weightFilename: "weights.npz",
                weightBytes: 1_524_924_912,
                weightSHA256: "10b597c2bcb1bcc38b2d3d24cd4f0885f461a7cd70e8444d6ad5a763ece549ea"
            )
        case (.whisper, "mlx-community/whisper-large-v3-mlx"):
            return whisperManifest(
                modelID: modelID,
                revision: "49e6aa286ad60c14352c404340ded53710378a11",
                configBytes: 269,
                configSHA256: "34982ce6ae286095000f82ae9583b3431639e8b092bf60c961f203745e6500e3",
                weightFilename: "weights.npz",
                weightBytes: 3_083_520_416,
                weightSHA256: "05ff791ce3630fae47e7c51004e9666204d786246ec07cac6110af768099b40d"
            )
        case (.whisper, "mlx-community/whisper-large-v3-mlx-4bit"):
            return whisperManifest(
                modelID: modelID,
                revision: "d12b5d0043a6fe0c59af321617fba041d4e8e0c8",
                configBytes: 342,
                configSHA256: "2169666f6066dc3cb5b97456b14d799d9846fc713cb0bbd98367834b95726ec1",
                weightFilename: "model.safetensors",
                weightBytes: 973_124_280,
                weightSHA256: "52a8a2d1d43d7c63c077b68e5fe07e1f0090eb697cc961913b3ce955e3e74efe"
            )
        case (.parakeetTDT, "mlx-community/parakeet-tdt-0.6b-v2"):
            return huggingFaceManifest(
                modelID: modelID,
                revision: "8ae155301e23d820d82aa60d24817c900e69e487",
                files: [
                    ("config.json", 36_176, "9bd323e60afe2615c983a5d9fc3a2c0470df2a03edf90c0f861bd59509d07264"),
                    ("model.safetensors", 2_471_559_904, "b958c37a6baa6874a279108755c8f2818e27bf647d72d54800a234a421341dfe")
                ]
            )
        default:
            return nil
        }
    }

    private nonisolated static func whisperManifest(
        modelID: String,
        revision: String,
        configBytes: Int64,
        configSHA256: String,
        weightFilename: String,
        weightBytes: Int64,
        weightSHA256: String
    ) -> MLXModelDownloadManifest {
        var manifest = huggingFaceManifest(
            modelID: modelID,
            revision: revision,
            files: [
                ("config.json", configBytes, configSHA256),
                (weightFilename, weightBytes, weightSHA256)
            ]
        )
        let tokenizerRevision = "5f86d1d86363843179951550570367b37c5d6f78"
        manifest = MLXModelDownloadManifest(
            modelID: manifest.modelID,
            revision: manifest.revision,
            files: manifest.files + [
                MLXModelDownloadFile(
                    sourceURL: "https://raw.githubusercontent.com/openai/whisper/\(tokenizerRevision)/whisper/assets/gpt2.tiktoken",
                    localFilename: "gpt2.tiktoken",
                    expectedBytes: 835_554,
                    sha256: "306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930"
                ),
                MLXModelDownloadFile(
                    sourceURL: "https://raw.githubusercontent.com/openai/whisper/\(tokenizerRevision)/whisper/assets/multilingual.tiktoken",
                    localFilename: "multilingual.tiktoken",
                    expectedBytes: 816_730,
                    sha256: "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"
                )
            ]
        )
        return manifest
    }

    private nonisolated static func huggingFaceManifest(
        modelID: String,
        revision: String,
        files: [(String, Int64, String)]
    ) -> MLXModelDownloadManifest {
        MLXModelDownloadManifest(
            modelID: modelID,
            revision: revision,
            files: files.map { filename, size, sha256 in
                MLXModelDownloadFile(
                    sourceURL: "https://huggingface.co/\(modelID)/resolve/\(revision)/\(filename)",
                    localFilename: filename,
                    expectedBytes: size,
                    sha256: sha256
                )
            }
        )
    }
}
