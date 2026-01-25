import Foundation
import Combine
import os.log

enum MLXModelKind: String, CaseIterable, Identifiable {
    case whisper
    case parakeetTDT

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .whisper:
            return String(localized: "MLX Whisper")
        case .parakeetTDT:
            return String(localized: "MLX Parakeet")
        }
    }

    nonisolated var folderName: String {
        switch self {
        case .whisper:
            return "whisper"
        case .parakeetTDT:
            return "parakeet-tdt"
        }
    }
}

@MainActor
final class MLXModelManager: NSObject, ObservableObject {
    struct DownloadProgress: Equatable {
        var fraction: Double
        var bytesDownloaded: Int64
        var totalBytes: Int64
        var estimatedSecondsRemaining: Int?
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(DownloadProgress)
        case ready
        case failed(String)
    }

    @Published private(set) var state: DownloadState = .idle
    @Published private(set) var localStorageBytes: Int64 = 0
    @Published private(set) var totalStorageBytes: Int64 = 0
    @Published private(set) var repoSizeBytes: Int64?
    @Published var modelId: String {
        didSet {
            refreshStatus()
        }
    }

    let kind: MLXModelKind

    private let logger = Logger.settings
    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var activeItem: DownloadItem?
    private var activeContinuation: CheckedContinuation<URL, Error>?
    private var completedBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var expectedTotalBytes: Int64 = 0
    private var downloadStartTime: Date?
    private var storageTask: Task<Void, Never>?
    private var repoSizeTask: Task<Void, Never>?
    private var lastRepoSizeModelId: String?

    init(kind: MLXModelKind, modelId: String) {
        self.kind = kind
        self.modelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    private struct HFModelInfo: Decodable {
        let siblings: [HFSibling]
        let usedStorage: Int64?
    }

    private struct HFSibling: Decodable {
        let rfilename: String
    }

    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]

        enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }

    struct DownloadItem {
        let url: URL
        let destination: URL
    }

    var modelDirectory: URL {
        Self.modelDirectory(for: kind, modelId: normalizedModelId)
    }

    nonisolated static var modelsRoot: URL {
        #if os(iOS)
        // On iOS, use the app's documents directory
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir
            .appendingPathComponent("vvterm", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        #else
        // On macOS App Store builds, keep models inside the sandbox container.
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupportDir
            .appendingPathComponent("VVTerm", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        #endif
    }

    var isModelAvailable: Bool {
        Self.isModelAvailable(kind: kind, modelId: normalizedModelId)
    }

    func refreshStatus() {
        if isModelAvailable {
            state = .ready
        } else if case .downloading = state {
            return
        } else {
            state = .idle
        }
        refreshStorageUsage()
        refreshRepoSize()
    }

    func removeModel() {
        do {
            if FileManager.default.fileExists(atPath: modelDirectory.path) {
                try FileManager.default.removeItem(at: modelDirectory)
            }
            state = .idle
            refreshStorageUsage()
        } catch {
            logger.error("Failed to remove MLX model: \(error.localizedDescription)")
            state = .failed(String(localized: "Failed to remove model"))
        }
    }

    static func clearAllStorage() {
        let root = modelsRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func downloadModel() async {
        if case .downloading = state { return }

        let modelId = normalizedModelId
        guard !modelId.isEmpty else {
            state = .failed(String(localized: "Model ID is required"))
            return
        }

        do {
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

            let items = try await resolveDownloadItems()

            completedBytes = 0
            currentFileBytes = 0
            expectedTotalBytes = repoSizeBytes ?? 0
            downloadStartTime = Date()
            state = .downloading(DownloadProgress(fraction: 0, bytesDownloaded: 0, totalBytes: expectedTotalBytes, estimatedSecondsRemaining: nil))

            for item in items {
                currentFileBytes = 0
                try await download(item)
                completedBytes += currentFileBytes
            }

            state = .ready
            refreshStorageUsage()
        } catch {
            logger.error("Failed to download MLX model: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    static func isModelAvailable(kind: MLXModelKind, modelId: String) -> Bool {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let directory = modelDirectory(for: kind, modelId: normalized)
        let config = directory.appendingPathComponent("config.json")
        let weights = weightFiles(in: directory, allowedExtensions: allowedWeightExtensions(for: kind))
        return FileManager.default.fileExists(atPath: config.path) && !weights.isEmpty
    }

    nonisolated static func modelDirectory(for kind: MLXModelKind, modelId: String) -> URL {
        let sanitized = sanitizeModelId(modelId)
        return modelsRoot
            .appendingPathComponent(kind.folderName, isDirectory: true)
            .appendingPathComponent(sanitized, isDirectory: true)
    }

    nonisolated static func weightFiles(in directory: URL, allowedExtensions: Set<String>) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }

    static func allowedWeightExtensions(for kind: MLXModelKind) -> Set<String> {
        return Set(["safetensors", "npz"])
    }

    private var normalizedModelId: String {
        modelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func sanitizeModelId(_ modelId: String) -> String {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.isEmpty ? "unknown-model" : trimmed
        return collapsed.replacingOccurrences(of: "/", with: "--")
    }

    nonisolated private static func directorySizeBytes(_ directory: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    func refreshStorageUsage() {
        storageTask?.cancel()
        let modelDir = modelDirectory
        let rootDir = Self.modelsRoot
        storageTask = Task.detached { [weak self] in
            let modelBytes = Self.directorySizeBytes(modelDir)
            let rootBytes = Self.directorySizeBytes(rootDir)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.localStorageBytes = modelBytes
                self.totalStorageBytes = rootBytes
            }
        }
    }

    func refreshRepoSize() {
        let modelId = normalizedModelId
        guard !modelId.isEmpty else {
            repoSizeBytes = nil
            return
        }
        if lastRepoSizeModelId == modelId, repoSizeBytes != nil {
            return
        }
        repoSizeTask?.cancel()
        lastRepoSizeModelId = modelId
        repoSizeBytes = nil
        repoSizeTask = Task.detached { [weak self] in
            let size = await MLXModelSizeCache.shared.size(for: modelId)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.repoSizeBytes = size
            }
        }
    }

    private func resolveDownloadItems() async throws -> [DownloadItem] {
        let modelId = normalizedModelId
        let base = "https://huggingface.co/\(modelId)/resolve/main"
        var configPath: String?
        var weightPaths: [String] = []
        let allowedExtensions = Self.allowedWeightExtensions(for: kind)

        if let files = try? await fetchModelFiles() {
            configPath = files.first { $0.hasSuffix("config.json") }

            if let indexPath = files.first(where: { $0.hasSuffix(".safetensors.index.json") }) {
                let indexURL = URL(string: "\(base)/\(indexPath)")!
                let (data, _) = try await session.data(from: indexURL)
                let index = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
                weightPaths = Array(Set(index.weightMap.values)).sorted()
            }

            if weightPaths.isEmpty {
                if let safetensors = files.first(where: { $0.hasSuffix(".safetensors") }) {
                    weightPaths = [safetensors]
                } else if let npz = files.first(where: { $0.hasSuffix(".npz") }) {
                    weightPaths = [npz]
                }
            }
        }

        if configPath == nil {
            configPath = "config.json"
        }

        if weightPaths.isEmpty {
            if let indexed = try await resolveWeightsFromIndex(base: base) {
                weightPaths = indexed
            }
        }

        if !weightPaths.isEmpty {
            weightPaths = weightPaths.filter { path in
                allowedExtensions.contains((path as NSString).pathExtension.lowercased())
            }
            let hasSafetensors = weightPaths.contains { ($0 as NSString).pathExtension.lowercased() == "safetensors" }
            if hasSafetensors {
                weightPaths = weightPaths.filter { ($0 as NSString).pathExtension.lowercased() == "safetensors" }
            }
        }

        if weightPaths.isEmpty {
            weightPaths = try await resolveWeightsFallback(base: base, allowedExtensions: allowedExtensions)
        }

        guard !weightPaths.isEmpty else {
            throw NSError(domain: "MLXModelManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "No compatible weights found for this model"])
        }

        let configURL = URL(string: "\(base)/\(configPath!)")!
        var items: [DownloadItem] = [
            DownloadItem(url: configURL, destination: modelDirectory.appendingPathComponent("config.json"))
        ]

        for path in weightPaths {
            let url = URL(string: "\(base)/\(path)")!
            items.append(DownloadItem(url: url, destination: modelDirectory.appendingPathComponent((path as NSString).lastPathComponent)))
        }

        if kind == .whisper {
            let tokenizerBase = "https://raw.githubusercontent.com/openai/whisper/main/whisper/assets"
            let tokenizerFiles = ["gpt2.tiktoken", "multilingual.tiktoken"]
            for name in tokenizerFiles {
                if let url = URL(string: "\(tokenizerBase)/\(name)") {
                    items.append(DownloadItem(url: url, destination: modelDirectory.appendingPathComponent(name)))
                }
            }
        }

        return items
    }

    private func fetchModelFiles() async throws -> [String] {
        let url = URL(string: "https://huggingface.co/api/models/\(normalizedModelId)")!
        let (data, _) = try await session.data(from: url)
        let info = try JSONDecoder().decode(HFModelInfo.self, from: data)
        return info.siblings.map(\.rfilename)
    }

    private func resolveWeightsFallback(base: String, allowedExtensions: Set<String>) async throws -> [String] {
        let candidates = ["model.safetensors", "weights.safetensors", "weights.npz", "model.npz"]
        for name in candidates {
            let ext = (name as NSString).pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            let url = URL(string: "\(base)/\(name)")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            do {
                let response = try await session.data(for: request).1
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    return [name]
                }
            } catch {
                continue
            }
        }
        return []
    }

    private func resolveWeightsFromIndex(base: String) async throws -> [String]? {
        let indexNames = ["model.safetensors.index.json", "weights.safetensors.index.json"]
        for name in indexNames {
            let url = URL(string: "\(base)/\(name)")!
            do {
                let (data, _) = try await session.data(from: url)
                let index = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
                let weights = Array(Set(index.weightMap.values)).sorted()
                if !weights.isEmpty {
                    return weights
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func download(_ item: DownloadItem) async throws {
        activeItem = item
        let task = session.downloadTask(with: item.url)
        activeTask = task

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            activeContinuation = continuation
            task.resume()
        }
    }

    private func updateProgress(currentBytes: Int64, currentTotalBytes: Int64) {
        currentFileBytes = currentBytes
        let totalDownloaded = completedBytes + currentBytes

        let fraction: Double
        let totalBytes: Int64
        if expectedTotalBytes > 0 {
            fraction = Double(totalDownloaded) / Double(expectedTotalBytes)
            totalBytes = expectedTotalBytes
        } else if currentTotalBytes > 0 {
            fraction = Double(currentBytes) / Double(currentTotalBytes)
            totalBytes = currentTotalBytes
        } else {
            fraction = 0
            totalBytes = 0
        }

        var eta: Int?
        if let startTime = downloadStartTime, totalDownloaded > 0 {
            let elapsed = Date().timeIntervalSince(startTime)
            let bytesPerSecond = Double(totalDownloaded) / elapsed
            if bytesPerSecond > 0 {
                let remainingBytes = totalBytes - totalDownloaded
                eta = Int(Double(remainingBytes) / bytesPerSecond)
            }
        }

        state = .downloading(DownloadProgress(
            fraction: min(max(fraction, 0), 1),
            bytesDownloaded: totalDownloaded,
            totalBytes: totalBytes,
            estimatedSecondsRemaining: eta
        ))
    }
}

extension MLXModelManager: @preconcurrency URLSessionDownloadDelegate {
    @MainActor
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let item = activeItem else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            let status = response.statusCode
            activeContinuation?.resume(throwing: NSError(
                domain: "MLXModelManager",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Download failed with status \(status)"]
            ))
            activeContinuation = nil
            activeTask = nil
            activeItem = nil
            return
        }
        do {
            if FileManager.default.fileExists(atPath: item.destination.path) {
                try FileManager.default.removeItem(at: item.destination)
            }
            try FileManager.default.moveItem(at: location, to: item.destination)
            activeContinuation?.resume(returning: item.destination)
        } catch {
            activeContinuation?.resume(throwing: error)
        }
        activeContinuation = nil
        activeTask = nil
        activeItem = nil
    }

    @MainActor
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            self.updateProgress(currentBytes: totalBytesWritten, currentTotalBytes: totalBytesExpectedToWrite)
        }
    }

    @MainActor
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            activeContinuation?.resume(throwing: error)
            activeContinuation = nil
            activeTask = nil
            activeItem = nil
        }
    }
}
