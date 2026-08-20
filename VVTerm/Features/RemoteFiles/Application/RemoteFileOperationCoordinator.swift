import Combine
import Foundation

/// Owns asynchronous operations for one Remote Files tab.
@MainActor
final class RemoteFileOperationCoordinator: ObservableObject {
    enum PreparedFilePurpose: Hashable {
        case downloadExport
        case share
    }

    struct PreparedFile: Identifiable {
        let id: UUID
        let purpose: PreparedFilePurpose
        let url: URL
        let filename: String
    }

    enum Kind: Equatable {
        case upload
        case transfer
    }

    enum Phase: Equatable {
        case running(message: String, completedUnitCount: Int?, totalUnitCount: Int?)
        case awaitingSecurityApproval(message: String)
        case succeeded(message: String)
        case failed(message: String)
    }

    struct Completion: Equatable {
        let fileURL: URL?
        let fileName: String?
        let filePath: String?

        init(fileURL: URL? = nil, fileName: String? = nil, filePath: String? = nil) {
            self.fileURL = fileURL
            self.fileName = fileName
            self.filePath = filePath
        }
    }

    struct Operation: Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        let title: String
        var phase: Phase
        var completion: Completion?
    }

    typealias ProgressHandler = @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void
    typealias TransferOperation = @MainActor (@escaping ProgressHandler) async throws -> Void

    private struct PreparedFileRecord {
        let file: PreparedFile
        let cleanup: @MainActor () -> Void
    }

    private struct PendingApproval {
        let taskID: UUID?
        let visibleOperationID: UUID?
        let request: ServerSecurityApprovalRequest
        let retry: @MainActor () -> Void
        let cancellation: @MainActor () -> Void
        let approvalFailure: @MainActor (Error) -> Void
    }

    @Published private(set) var operations: [Operation] = []
    @Published private var pendingApproval: PendingApproval?

    private let server: Server
    private let securityApprovalActions: RemoteFileSecurityApprovalActions
    private var tasksByID: [UUID: Task<Void, Never>] = [:]
    private var dismissalTasksByID: [UUID: Task<Void, Never>] = [:]
    private var preparedFilesByID: [UUID: PreparedFileRecord] = [:]
    private var latestPreparedFileRequestByPurpose: [PreparedFilePurpose: UUID] = [:]

    var securityApprovalRequest: ServerSecurityApprovalRequest? {
        pendingApproval?.request
    }

    init(server: Server, securityApprovalActions: RemoteFileSecurityApprovalActions) {
        self.server = server
        self.securityApprovalActions = securityApprovalActions
    }

    @discardableResult
    func start(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        initialMessage: String,
        successMessage: String,
        completion: Completion = Completion(),
        keepsSuccessVisible: Bool = false,
        onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping TransferOperation
    ) -> UUID {
        setOperation(Operation(
            id: id,
            kind: kind,
            title: title,
            phase: .running(
                message: initialMessage,
                completedUnitCount: nil,
                totalUnitCount: nil
            ),
            completion: nil
        ))
        launchTransfer(
            id: id,
            kind: kind,
            title: title,
            successMessage: successMessage,
            completion: completion,
            keepsSuccessVisible: keepsSuccessVisible,
            onSuccess: onSuccess,
            allowsSecurityRetry: true,
            operation: operation
        )
        return id
    }

    @discardableResult
    func run<Result>(
        operation: @escaping @MainActor () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> UUID {
        let id = UUID()
        launchOperation(
            id: id,
            allowsSecurityRetry: true,
            operation: operation,
            onSuccess: onSuccess,
            onFailure: onFailure
        )
        return id
    }

    @discardableResult
    func requestSecurityApproval(
        for error: Error,
        retry: @escaping @MainActor () -> Void,
        onCancellation: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        beginSecurityApprovalIfNeeded(
            for: error,
            taskID: nil,
            retry: retry,
            onCancellation: onCancellation
        )
    }

    func contains(_ id: UUID) -> Bool {
        tasksByID[id] != nil || operations.contains { $0.id == id }
    }

    func cancel(_ id: UUID) {
        tasksByID.removeValue(forKey: id)?.cancel()
        dismissalTasksByID.removeValue(forKey: id)?.cancel()
        if pendingApproval?.taskID == id {
            rejectPendingApproval()
            clearPendingApproval()
        }
        removeOperation(id)
    }

    func dismiss(_ id: UUID) {
        guard tasksByID[id] == nil else { return }
        dismissalTasksByID.removeValue(forKey: id)?.cancel()
        removeOperation(id)
    }

    func releasePreparedFile(_ id: UUID) {
        guard let record = preparedFilesByID.removeValue(forKey: id) else { return }
        if latestPreparedFileRequestByPurpose[record.file.purpose] == id {
            latestPreparedFileRequestByPurpose[record.file.purpose] = nil
        }
        record.cleanup()
    }

    func beginPreparedFileRequest(_ id: UUID, purpose: PreparedFilePurpose) {
        if let previousID = latestPreparedFileRequestByPurpose[purpose], previousID != id {
            cancel(previousID)
            releasePreparedFile(previousID)
        }
        latestPreparedFileRequestByPurpose[purpose] = id
    }

    func publishPreparedFile(
        _ file: PreparedFile,
        cleanup: @escaping @MainActor () -> Void,
        onPrepared: @escaping @MainActor (PreparedFile) -> Void
    ) {
        guard latestPreparedFileRequestByPurpose[file.purpose] == file.id else {
            cleanup()
            return
        }
        preparedFilesByID[file.id] = PreparedFileRecord(file: file, cleanup: cleanup)
        onPrepared(file)
    }

    func approveSecurityRequest() -> Error? {
        guard let pendingApproval else { return nil }
        guard securityApprovalActions.approve(pendingApproval.request) else {
            if let operationID = pendingApproval.visibleOperationID {
                fail(operationID, message: ServerSecurityApprovalError.expired.localizedDescription)
            }
            pendingApproval.approvalFailure(ServerSecurityApprovalError.expired)
            let error: Error? = pendingApproval.taskID == nil
                ? ServerSecurityApprovalError.expired
                : nil
            clearPendingApproval()
            return error
        }
        let retry = pendingApproval.retry
        clearPendingApproval()
        retry()
        return nil
    }

    func cancelSecurityRequest() -> Error? {
        guard let pendingApproval else { return nil }
        rejectPendingApproval()
        if let operationID = pendingApproval.visibleOperationID {
            fail(operationID, message: ServerSecurityApprovalError.cancelled.localizedDescription)
        }
        let error: Error? = pendingApproval.taskID == nil
            ? ServerSecurityApprovalError.cancelled
            : nil
        let cancellation = pendingApproval.cancellation
        clearPendingApproval()
        cancellation()
        return error
    }

    func cancelAll() {
        let tasks = Array(tasksByID.values) + Array(dismissalTasksByID.values)
        tasksByID.removeAll(keepingCapacity: false)
        dismissalTasksByID.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        let preparedFiles = Array(preparedFilesByID.values)
        preparedFilesByID.removeAll(keepingCapacity: false)
        latestPreparedFileRequestByPurpose.removeAll(keepingCapacity: false)
        preparedFiles.forEach { $0.cleanup() }
        rejectPendingApproval()
        clearPendingApproval()
        operations.removeAll(keepingCapacity: false)
    }

    private func launchTransfer(
        id: UUID,
        kind: Kind,
        title: String,
        successMessage: String,
        completion: Completion,
        keepsSuccessVisible: Bool,
        onSuccess: (@MainActor () -> Void)?,
        allowsSecurityRetry: Bool,
        operation: @escaping TransferOperation
    ) {
        tasksByID[id]?.cancel()
        tasksByID[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation { [weak self] progress in
                    self?.report(progress, for: id)
                }
                try Task.checkCancellation()
                tasksByID[id] = nil
                setOperation(Operation(
                    id: id,
                    kind: kind,
                    title: title,
                    phase: .succeeded(message: successMessage),
                    completion: completion
                ))
                onSuccess?()
                if !keepsSuccessVisible { scheduleDismissal(for: id) }
            } catch is CancellationError {
                tasksByID[id] = nil
                removeOperation(id)
            } catch {
                tasksByID[id] = nil
                if allowsSecurityRetry,
                   beginSecurityApprovalIfNeeded(
                       for: error,
                       taskID: id,
                       visibleOperationID: id,
                       retry: { [weak self] in
                           self?.launchTransfer(
                               id: id,
                               kind: kind,
                               title: title,
                               successMessage: successMessage,
                               completion: completion,
                               keepsSuccessVisible: keepsSuccessVisible,
                               onSuccess: onSuccess,
                               allowsSecurityRetry: false,
                               operation: operation
                           )
                       }
                   ) {
                    setAwaitingApproval(id)
                    return
                }
                fail(id, message: errorMessage(for: error, allowsSecurityRetry: allowsSecurityRetry))
            }
        }
    }

    private func launchOperation<Result>(
        id: UUID,
        allowsSecurityRetry: Bool,
        operation: @escaping @MainActor () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        tasksByID[id]?.cancel()
        tasksByID[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await operation()
                try Task.checkCancellation()
                tasksByID[id] = nil
                onSuccess(result)
            } catch is CancellationError {
                tasksByID[id] = nil
            } catch {
                tasksByID[id] = nil
                if allowsSecurityRetry,
                   beginSecurityApprovalIfNeeded(
                       for: error,
                       taskID: id,
                       retry: { [weak self] in
                           self?.launchOperation(
                               id: id,
                               allowsSecurityRetry: false,
                               operation: operation,
                               onSuccess: onSuccess,
                               onFailure: onFailure
                           )
                       },
                       onCancellation: { onFailure(ServerSecurityApprovalError.cancelled) },
                       onApprovalFailure: onFailure
                   ) {
                    return
                }
                onFailure(
                    !allowsSecurityRetry && RemoteFileBrowserError.map(error) == .hostKeyApprovalRequired
                        ? ServerSecurityApprovalError.unavailable
                        : error
                )
            }
        }
    }

    private func report(_ progress: RemoteFileBrowserStore.TransferProgress, for id: UUID) {
        guard var current = operations.first(where: { $0.id == id }) else { return }
        let itemName = progress.currentItemName.isEmpty ? String(localized: "item") : progress.currentItemName
        let message: String
        if current.kind == .upload, progress.completedUnitCount == 0 {
            message = String(format: String(localized: "Uploading %@"), itemName)
        } else {
            message = String(
                format: String(localized: "%lld of %lld: %@"),
                Int64(progress.completedUnitCount),
                Int64(progress.totalUnitCount),
                itemName
            )
        }
        current.phase = .running(
            message: message,
            completedUnitCount: progress.completedUnitCount,
            totalUnitCount: progress.totalUnitCount
        )
        setOperation(current)
    }

    private func beginSecurityApprovalIfNeeded(
        for error: Error,
        taskID: UUID?,
        visibleOperationID: UUID? = nil,
        retry: @escaping @MainActor () -> Void,
        onCancellation: @escaping @MainActor () -> Void = {},
        onApprovalFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> Bool {
        guard pendingApproval == nil,
              let request = securityApprovalActions.pendingRequest(error, server)
        else { return false }
        pendingApproval = PendingApproval(
            taskID: taskID,
            visibleOperationID: visibleOperationID,
            request: request,
            retry: retry,
            cancellation: onCancellation,
            approvalFailure: onApprovalFailure
        )
        return true
    }

    private func setAwaitingApproval(_ id: UUID) {
        guard var current = operations.first(where: { $0.id == id }) else { return }
        current.phase = .awaitingSecurityApproval(
            message: String(localized: "Approve the server identity to continue.")
        )
        setOperation(current)
    }

    private func fail(_ id: UUID, message: String) {
        guard var current = operations.first(where: { $0.id == id }) else { return }
        current.phase = .failed(message: message)
        setOperation(current)
    }

    private func errorMessage(for error: Error, allowsSecurityRetry: Bool) -> String {
        let mapped = RemoteFileBrowserError.map(error)
        if !allowsSecurityRetry, mapped == .hostKeyApprovalRequired {
            return ServerSecurityApprovalError.unavailable.localizedDescription
        }
        return mapped.errorDescription ?? error.localizedDescription
    }

    private func setOperation(_ operation: Operation) {
        if let index = operations.firstIndex(where: { $0.id == operation.id }) {
            guard operations[index] != operation else { return }
            operations[index] = operation
        } else {
            operations.append(operation)
        }
    }

    private func removeOperation(_ id: UUID) {
        operations.removeAll { $0.id == id }
    }

    private func scheduleDismissal(for id: UUID) {
        dismissalTasksByID[id]?.cancel()
        dismissalTasksByID[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.dismissalTasksByID[id] = nil
            self?.removeOperation(id)
        }
    }

    private func rejectPendingApproval() {
        guard let request = pendingApproval?.request else { return }
        securityApprovalActions.reject(request)
    }

    private func clearPendingApproval() {
        pendingApproval = nil
    }

    isolated deinit {
        tasksByID.values.forEach { $0.cancel() }
        dismissalTasksByID.values.forEach { $0.cancel() }
    }
}
