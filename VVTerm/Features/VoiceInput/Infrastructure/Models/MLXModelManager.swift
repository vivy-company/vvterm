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

nonisolated struct MLXDownloadOperationState: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case resolving(operationID: UUID)
        case downloading(operationID: UUID, taskIdentifier: Int)
        case shutdown
    }

    private(set) var phase: Phase = .idle

    mutating func start() -> UUID? {
        guard phase == .idle else { return nil }
        let operationID = UUID()
        phase = .resolving(operationID: operationID)
        return operationID
    }

    mutating func beginTask(operationID: UUID, taskIdentifier: Int) -> Bool {
        guard phase == .resolving(operationID: operationID) else { return false }
        phase = .downloading(operationID: operationID, taskIdentifier: taskIdentifier)
        return true
    }

    func accepts(taskIdentifier: Int) -> Bool {
        guard case .downloading(_, let activeTaskIdentifier) = phase else { return false }
        return activeTaskIdentifier == taskIdentifier
    }

    @discardableResult
    mutating func finishTask(taskIdentifier: Int) -> Bool {
        guard case .downloading(let operationID, let activeTaskIdentifier) = phase,
              activeTaskIdentifier == taskIdentifier else { return false }
        phase = .resolving(operationID: operationID)
        return true
    }

    @discardableResult
    mutating func finish(operationID: UUID) -> Bool {
        guard phase == .resolving(operationID: operationID) else { return false }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func cancel(operationID: UUID) -> Bool {
        let activeOperationID: UUID
        switch phase {
        case .idle, .shutdown:
            return false
        case .resolving(let operationID), .downloading(let operationID, _):
            activeOperationID = operationID
        }
        guard activeOperationID == operationID else { return false }
        phase = .idle
        return true
    }

    func isActive(operationID: UUID) -> Bool {
        switch phase {
        case .idle, .shutdown:
            return false
        case .resolving(let activeOperationID), .downloading(let activeOperationID, _):
            return activeOperationID == operationID
        }
    }

    mutating func shutdown() {
        phase = .shutdown
    }

    var isShutdown: Bool {
        phase == .shutdown
    }
}

@MainActor
struct MLXModelSessionLifecycle {
    let configuration: URLSessionConfiguration
    let invalidate: @MainActor (URLSession) -> Void

    static var live: Self {
        MLXModelSessionLifecycle(
            configuration: .default,
            invalidate: { $0.invalidateAndCancel() }
        )
    }
}

nonisolated struct MLXModelManagerOperations: Sendable {
    let adoptLegacyDownload: @Sendable (
        _ root: URL,
        _ kind: MLXModelKind,
        _ modelID: String
    ) async -> MLXLegacyModelAdoptionResult

    static let live = MLXModelManagerOperations(
        adoptLegacyDownload: { root, kind, modelID in
            MLXModelLegacyAdopter.adoptIfPossible(
                root: root,
                kind: kind,
                modelID: modelID
            )
        }
    )
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
        case checkingLegacyDownload
        case downloading(DownloadProgress)
        case ready
        case updateRequired
        case failed(String)
    }

    @Published private(set) var state: DownloadState = .idle
    @Published private(set) var localStorageBytes: Int64 = 0
    @Published private(set) var totalStorageBytes: Int64 = 0
    @Published private(set) var repoSizeBytes: Int64?
    let kind: MLXModelKind

    var modelId: String { selectedModelID() }

    private let logger = Logger.settings
    private let selectedModelID: @MainActor () -> String
    private let storageRoot: URL
    private let sessionLifecycle: MLXModelSessionLifecycle
    private let operations: MLXModelManagerOperations
    private var session: URLSession?
    private var operationState = MLXDownloadOperationState()
    private var activeContext: DownloadContext?
    private var activeFile: ActiveFileDownload?
    private var completedBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var expectedTotalBytes: Int64 = 0
    private var downloadStartTime: Date?
    private var storageTask: Task<Void, Never>?
    private var storageOperationID: UUID?
    private var statusTask: Task<Void, Never>?
    private var statusOperationID: UUID?
    private var pendingLegacyCleanup: Set<URL> = []

    init(
        kind: MLXModelKind,
        selectedModelID: @escaping @MainActor () -> String,
        storageRoot: URL,
        sessionLifecycle: MLXModelSessionLifecycle,
        operations: MLXModelManagerOperations
    ) {
        self.kind = kind
        self.selectedModelID = selectedModelID
        self.storageRoot = storageRoot
        self.sessionLifecycle = sessionLifecycle
        self.operations = operations
        super.init()
        session = URLSession(
            configuration: sessionLifecycle.configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    isolated deinit {
        if let session {
            sessionLifecycle.invalidate(session)
        }
    }

    struct DownloadItem {
        let url: URL
        let destination: URL
        let expectedBytes: Int64
        let sha256: String
    }

    private struct DownloadContext {
        let modelID: String
        let manifest: MLXModelDownloadManifest
        let finalDirectory: URL
        let stagingDirectory: URL
    }

    private struct ActiveFileDownload {
        let task: URLSessionDownloadTask
        let item: DownloadItem
        let continuation: CheckedContinuation<URL, Error>
    }

    var modelDirectory: URL {
        Self.modelDirectory(
            for: kind,
            modelId: normalizedModelId,
            modelsRoot: storageRoot
        )
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
        Self.isModelAvailable(
            kind: kind,
            modelId: normalizedModelId,
            modelsRoot: storageRoot
        )
    }

    func refreshStatus() {
        guard !operationState.isShutdown else { return }
        if isModelAvailable {
            statusTask?.cancel()
            state = .ready
        } else if case .downloading = state {
            return
        } else {
            refreshLegacyDownloadStatus()
        }
        refreshStorageUsage()
        refreshRepoSize()
    }

    private func refreshLegacyDownloadStatus() {
        statusTask?.cancel()
        let operationID = UUID()
        statusOperationID = operationID
        let root = storageRoot
        let kind = kind
        let modelID = normalizedModelId

        if case .unsupported = MLXModelLegacyMigration.resolveModelID(modelID, kind: kind) {
            state = .updateRequired
            return
        }

        state = .checkingLegacyDownload
        let operations = operations
        statusTask = Task.detached { [weak self, operations] in
            let result = await operations.adoptLegacyDownload(root, kind, modelID)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.statusOperationID == operationID,
                      self.normalizedModelId == modelID else {
                    return
                }
                switch result {
                case .adopted:
                    self.state = .ready
                case .noLegacyDownload:
                    self.state = .idle
                case .updateRequired:
                    self.state = .updateRequired
                }
                self.refreshStorageUsage()
            }
        }
    }

    func removeModel() {
        guard !operationState.isShutdown else { return }
        cancelActiveDownload()
        statusTask?.cancel()
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

    func removeIncompatibleDownload() {
        guard !operationState.isShutdown else { return }
        cancelActiveDownload()
        statusTask?.cancel()
        do {
            try MLXModelLegacyAdopter.removeIncompatibleDownloads(
                root: storageRoot,
                kind: kind,
                modelID: normalizedModelId
            )
            pendingLegacyCleanup.removeAll()
            state = .idle
            refreshStorageUsage()
        } catch {
            logger.error("Failed to remove incompatible MLX model: \(error.localizedDescription)")
            state = .failed(String(localized: "Failed to remove model"))
        }
    }

    func clearAllStorage() {
        guard FileManager.default.fileExists(atPath: storageRoot.path) else { return }
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func downloadModel() async {
        guard !operationState.isShutdown else { return }
        statusTask?.cancel()
        let modelId = normalizedModelId
        guard !modelId.isEmpty else {
            state = .failed(String(localized: "Model ID is required"))
            return
        }
        guard let manifest = MLXModelCatalog.downloadManifest(for: modelId, kind: kind) else {
            state = .failed(MLXModelDownloadError.unsupportedModel.localizedDescription)
            return
        }
        guard let operationID = operationState.start() else { return }

        let finalDirectory = Self.modelDirectory(
            for: kind,
            modelId: modelId,
            modelsRoot: storageRoot
        )
        let stagingDirectory = finalDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(finalDirectory.lastPathComponent)-\(operationID.uuidString).download", isDirectory: true)
        let context = DownloadContext(
            modelID: modelId,
            manifest: manifest,
            finalDirectory: finalDirectory,
            stagingDirectory: stagingDirectory
        )
        activeContext = context
        completedBytes = 0
        currentFileBytes = 0
        expectedTotalBytes = manifest.expectedBytes ?? 0
        downloadStartTime = Date()
        state = .downloading(DownloadProgress(
            fraction: 0,
            bytesDownloaded: 0,
            totalBytes: expectedTotalBytes,
            estimatedSecondsRemaining: nil
        ))

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let capacity = try Self.availableStorageCapacity(at: storageRoot)
            expectedTotalBytes = try MLXModelDownloadBudget.validate(
                manifest: manifest,
                currentRepositoryBytes: Self.directorySizeBytes(storageRoot),
                availableCapacity: capacity
            )
            if fileManager.fileExists(atPath: context.stagingDirectory.path) {
                try fileManager.removeItem(at: context.stagingDirectory)
            }
            try fileManager.createDirectory(at: context.stagingDirectory, withIntermediateDirectories: true)

            let items = try resolveDownloadItems(context: context)
            guard operationState.isActive(operationID: operationID) else { return }

            for item in items {
                currentFileBytes = 0
                try await download(item, operationID: operationID)
                completedBytes = Self.addingBytes(completedBytes, item.expectedBytes)
            }

            try Data(manifest.revision.utf8).write(
                to: context.stagingDirectory.appendingPathComponent(MLXModelDownloadManifest.markerFilename),
                options: .atomic
            )
            try MLXModelStorageInstaller.install(
                stagingDirectory: context.stagingDirectory,
                finalDirectory: context.finalDirectory
            )
            try? MLXModelLegacyAdopter.removeIncompatibleDownloads(
                root: storageRoot,
                kind: kind,
                modelID: modelId
            )
            for directory in pendingLegacyCleanup
                where FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
            pendingLegacyCleanup.removeAll()
            guard operationState.finish(operationID: operationID) else { return }
            activeContext = nil
            state = .ready
            refreshStorageUsage()
        } catch {
            try? FileManager.default.removeItem(at: context.stagingDirectory)
            guard operationState.finish(operationID: operationID) else { return }
            activeContext = nil
            logger.error("Failed to download MLX model: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated static func isModelAvailable(kind: MLXModelKind, modelId: String) -> Bool {
        isModelAvailable(kind: kind, modelId: modelId, modelsRoot: modelsRoot)
    }

    nonisolated static func isModelAvailable(
        kind: MLXModelKind,
        modelId: String,
        modelsRoot: URL
    ) -> Bool {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let manifest = MLXModelCatalog.downloadManifest(for: normalized, kind: kind) else {
            return false
        }
        let directory = modelDirectory(for: kind, modelId: normalized, modelsRoot: modelsRoot)
        let marker = directory.appendingPathComponent(MLXModelDownloadManifest.markerFilename)
        guard let revisionData = try? Data(contentsOf: marker),
              String(data: revisionData, encoding: .utf8) == manifest.revision else {
            return false
        }
        let config = directory.appendingPathComponent("config.json")
        let weights = weightFiles(in: directory, allowedExtensions: allowedWeightExtensions(for: kind))
        guard FileManager.default.fileExists(atPath: config.path), !weights.isEmpty else { return false }
        return manifest.files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.localFilename)
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) == file.expectedBytes
        }
    }

    nonisolated static func modelDirectory(for kind: MLXModelKind, modelId: String) -> URL {
        modelDirectory(for: kind, modelId: modelId, modelsRoot: modelsRoot)
    }

    nonisolated static func modelDirectory(
        for kind: MLXModelKind,
        modelId: String,
        modelsRoot: URL
    ) -> URL {
        MLXModelStorageLayout.currentDirectory(root: modelsRoot, kind: kind, modelID: modelId)
    }

    nonisolated static func weightFiles(in directory: URL, allowedExtensions: Set<String>) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }

    nonisolated static func allowedWeightExtensions(for kind: MLXModelKind) -> Set<String> {
        return Set(["safetensors", "npz"])
    }

    private var normalizedModelId: String {
        modelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func modelSelectionDidChange(from previousModelID: String) {
        guard !operationState.isShutdown else { return }
        recordPendingLegacyCleanup(for: previousModelID)
        if let activeContext, activeContext.modelID != normalizedModelId {
            cancelActiveDownload()
        }
        refreshStatus()
    }

    private func recordPendingLegacyCleanup(for previousModelID: String) {
        let previous = previousModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, previous != normalizedModelId else { return }

        for directory in MLXModelStorageLayout.legacyDirectories(
            root: storageRoot,
            kind: kind,
            modelID: previous
        ) where FileManager.default.fileExists(atPath: directory.path) {
            pendingLegacyCleanup.insert(directory)
        }

        let current = Self.modelDirectory(
            for: kind,
            modelId: previous,
            modelsRoot: storageRoot
        )
        if FileManager.default.fileExists(atPath: current.path),
           !Self.isModelAvailable(kind: kind, modelId: previous, modelsRoot: storageRoot) {
            pendingLegacyCleanup.insert(current)
        }
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
            total = addingBytes(total, Int64(size))
        }
        return total
    }

    nonisolated private static func availableStorageCapacity(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage,
              capacity >= 0 else {
            throw MLXModelDownloadError.insufficientFreeSpace
        }
        return capacity
    }

    func refreshStorageUsage() {
        guard !operationState.isShutdown else { return }
        storageTask?.cancel()
        let operationID = UUID()
        storageOperationID = operationID
        let modelDir = modelDirectory
        let rootDir = storageRoot
        storageTask = Task.detached { [weak self] in
            let modelBytes = Self.directorySizeBytes(modelDir)
            let rootBytes = Self.directorySizeBytes(rootDir)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.storageOperationID == operationID,
                      self.modelDirectory == modelDir else { return }
                self.localStorageBytes = modelBytes
                self.totalStorageBytes = rootBytes
            }
        }
    }

    func refreshRepoSize() {
        guard !operationState.isShutdown else { return }
        let modelId = normalizedModelId
        repoSizeBytes = MLXModelCatalog.downloadManifest(for: modelId, kind: kind)?.expectedBytes
    }

    private func resolveDownloadItems(context: DownloadContext) throws -> [DownloadItem] {
        try context.manifest.files.map { file in
            guard let url = URL(string: file.sourceURL) else {
                throw MLXModelDownloadError.invalidManifest
            }
            return DownloadItem(
                url: url,
                destination: context.stagingDirectory.appendingPathComponent(file.localFilename),
                expectedBytes: file.expectedBytes,
                sha256: file.sha256
            )
        }
    }

    private func download(_ item: DownloadItem, operationID: UUID) async throws {
        guard let session else { throw CancellationError() }
        let task = session.downloadTask(with: item.url)

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            guard operationState.beginTask(
                operationID: operationID,
                taskIdentifier: task.taskIdentifier
            ) else {
                continuation.resume(throwing: CancellationError())
                return
            }
            activeFile = ActiveFileDownload(task: task, item: item, continuation: continuation)
            task.resume()
        }
    }

    private func cancelActiveDownload() {
        guard let context = activeContext else { return }
        let operationID: UUID
        switch operationState.phase {
        case .idle, .shutdown:
            activeContext = nil
            return
        case .resolving(let id), .downloading(let id, _):
            operationID = id
        }

        guard operationState.cancel(operationID: operationID) else { return }
        activeContext = nil
        try? FileManager.default.removeItem(at: context.stagingDirectory)
        if let activeFile {
            self.activeFile = nil
            activeFile.continuation.resume(throwing: CancellationError())
            activeFile.task.cancel()
        }
        logger.info("Cancelled MLX model download for \(context.modelID)")
    }

    func shutdown() {
        guard !operationState.isShutdown else { return }
        cancelActiveDownload()
        operationState.shutdown()
        statusTask?.cancel()
        statusTask = nil
        statusOperationID = nil
        storageTask?.cancel()
        storageTask = nil
        storageOperationID = nil
        state = .idle
        if let session {
            self.session = nil
            sessionLifecycle.invalidate(session)
        }
    }

    private func completeActiveFile(
        taskIdentifier: Int,
        result: Result<URL, Error>
    ) {
        guard operationState.accepts(taskIdentifier: taskIdentifier),
              let activeFile,
              activeFile.task.taskIdentifier == taskIdentifier else { return }

        self.activeFile = nil
        operationState.finishTask(taskIdentifier: taskIdentifier)
        activeFile.continuation.resume(with: result)
    }

    nonisolated static func addingBytes(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private func updateProgress(currentBytes: Int64, currentTotalBytes: Int64) {
        currentFileBytes = currentBytes
        let totalDownloaded = Self.addingBytes(completedBytes, currentBytes)

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
                let remainingBytes = max(totalBytes - min(totalDownloaded, totalBytes), 0)
                let seconds = Double(remainingBytes) / bytesPerSecond
                if seconds.isFinite {
                    eta = seconds >= Double(Int.max) ? Int.max : Int(seconds)
                }
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
        guard operationState.accepts(taskIdentifier: downloadTask.taskIdentifier),
              let activeFile,
              activeFile.task.taskIdentifier == downloadTask.taskIdentifier else { return }
        let item = activeFile.item
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            let status = response.statusCode
            completeActiveFile(taskIdentifier: downloadTask.taskIdentifier, result: .failure(NSError(
                domain: "MLXModelManager",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Download failed with status \(status)"]
            )))
            return
        }
        if let response = downloadTask.response,
           response.expectedContentLength > 0,
           response.expectedContentLength != item.expectedBytes {
            completeActiveFile(
                taskIdentifier: downloadTask.taskIdentifier,
                result: .failure(MLXModelDownloadError.unexpectedResponseSize)
            )
            return
        }
        do {
            try MLXModelFileVerifier.verify(
                location,
                expectedBytes: item.expectedBytes,
                sha256: item.sha256
            )
            if FileManager.default.fileExists(atPath: item.destination.path) {
                try FileManager.default.removeItem(at: item.destination)
            }
            try FileManager.default.moveItem(at: location, to: item.destination)
            completeActiveFile(taskIdentifier: downloadTask.taskIdentifier, result: .success(item.destination))
        } catch {
            completeActiveFile(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    @MainActor
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard operationState.accepts(taskIdentifier: downloadTask.taskIdentifier),
              let activeFile,
              activeFile.task.taskIdentifier == downloadTask.taskIdentifier else { return }
        if totalBytesWritten > activeFile.item.expectedBytes
            || (totalBytesExpectedToWrite > 0
                && totalBytesExpectedToWrite != activeFile.item.expectedBytes) {
            activeFile.task.cancel()
            completeActiveFile(
                taskIdentifier: downloadTask.taskIdentifier,
                result: .failure(MLXModelDownloadError.unexpectedResponseSize)
            )
            return
        }
        updateProgress(currentBytes: totalBytesWritten, currentTotalBytes: totalBytesExpectedToWrite)
    }

    @MainActor
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        completeActiveFile(taskIdentifier: task.taskIdentifier, result: .failure(error))
    }
}
