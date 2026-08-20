import Combine
import Darwin
import Foundation

extension RemoteFileBrowserStore {
    struct LocalUploadItemInfo: Sendable {
        let name: String
        let identity: LocalFileIdentity
        let kind: LocalUploadPlanNode.Kind
    }

    final class TransferProgressTracker {
        private(set) var completedUnitCount = 0
        let totalUnitCount: Int
        let onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?

        init(
            totalUnitCount: Int,
            onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?
        ) {
            self.totalUnitCount = max(1, totalUnitCount)
            self.onProgress = onProgress
        }

        @MainActor
        func reportCurrentItem(_ currentItemName: String) {
            onProgress?(
                TransferProgress(
                    completedUnitCount: min(completedUnitCount, totalUnitCount),
                    totalUnitCount: totalUnitCount,
                    currentItemName: currentItemName
                )
            )
        }

        @MainActor
        func advance(currentItemName: String) {
            completedUnitCount += 1
            onProgress?(
                TransferProgress(
                    completedUnitCount: min(completedUnitCount, totalUnitCount),
                    totalUnitCount: totalUnitCount,
                    currentItemName: currentItemName
                )
            )
        }
    }

    func upload(
        data: Data,
        to remotePath: String,
        server: Server,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            try await service.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func createDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.createDirectory(at: remotePath, permissions: permissions)
        }
    }

    func createDirectory(
        named directoryName: String,
        in remoteDirectoryPath: String,
        tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        let leaf = try RemoteFileLeaf(validating: RemoteFilePathPolicy.validatedName(directoryName))
        let remotePath = RemoteFilePath.appending(leaf, to: remoteDirectoryPath)
        try await createDirectory(at: remotePath, in: tab, server: server, permissions: permissions)
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.renameItem(at: sourcePath, to: destinationPath)
        }
    }

    func deleteFile(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.deleteFile(at: remotePath)
        }
    }

    func deleteDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { [self] service in
            try await deleteDirectoryRecursively(at: remotePath, using: service)
        }
    }

    func deleteItem(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        type: RemoteFileType? = nil
    ) async throws {
        switch type {
        case .directory:
            try await deleteDirectory(at: remotePath, in: tab, server: server)
        case .file, .symlink, .other, nil:
            try await deleteFile(at: remotePath, in: tab, server: server)
        }
    }

    func setPermissions(
        _ entry: RemoteFileEntry,
        permissions: UInt32,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let updatedEntry = try await withRemoteFileService(for: server) { service in
            try await service.setPermissions(at: entry.path, permissions: permissions)
            return try await service.lstat(at: entry.path)
        }

        let requestedPermissionBits = permissions & 0o7777
        let updatedPermissionBits = (updatedEntry.permissions ?? 0) & 0o7777
        if updatedPermissionBits != requestedPermissionBits {
            throw RemoteFileBrowserError.failed(
                String(
                    localized: "This server accepted the request, but the file permissions did not change. Some remote systems, including many Windows SFTP servers, do not support POSIX chmod."
                )
            )
        }

        updateState(for: tab) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path,
               let payload = state.viewerPayload,
               payload.entry.path == entry.path {
                state.viewerPhase = .loaded(RemoteFileViewerPayload(
                    previewKind: payload.previewKind,
                    entry: updatedEntry,
                    textPreview: payload.textPreview,
                    previewFileURL: payload.previewFileURL,
                    isTruncated: payload.isTruncated,
                    unavailableMessage: payload.unavailableMessage,
                    requiresExplicitDownload: payload.requiresExplicitDownload,
                    previewByteCount: payload.previewByteCount
                ))
            }
        }
    }

    func uploadFilesResolvingConflicts(
        at urls: [URL],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        try await withSecurityScopedAccess(to: urls) {
            try Task.checkCancellation()
            let limits = RemoteFileTransferLimits.standard
            guard !urls.isEmpty else { return }
            guard urls.count <= limits.maxEntries else {
                throw RemoteFileTransferError.entryLimit(maximum: limits.maxEntries)
            }
            var traversalBudget = RemoteFileTraversalBudget(limits: limits)
            var byteBudget = RemoteFileTransferByteBudget(limits: limits)
            var visitedIdentities: Set<LocalFileIdentity> = []
            var plans: [LocalUploadPlanNode] = []
            plans.reserveCapacity(urls.count)
            for url in urls {
                plans.append(try await makeLocalUploadPlan(
                    at: url,
                    depth: 0,
                    traversalBudget: &traversalBudget,
                    byteBudget: &byteBudget,
                    visitedIdentities: &visitedIdentities
                ))
            }

            let progressTracker = TransferProgressTracker(
                totalUnitCount: plans.reduce(0) { $0 + $1.unitCount },
                onProgress: onProgress
            )

            try await withRemoteFileService(for: server) { [self] service in
                let capacity = try await service.fileSystemCapacity(at: destinationDirectory)
                try byteBudget.validateUploadCapacity(capacity)
                var reservedNames: Set<String> = []

                for plan in plans {
                    try Task.checkCancellation()
                    let resolution = try await conflictResolver.resolveName(
                        for: plan.name,
                        in: destinationDirectory,
                        policy: .keepBoth,
                        using: service,
                        reservedNames: &reservedNames
                    )
                    try await uploadLocalTransferPlan(
                        plan,
                        to: destinationDirectory,
                        remoteName: resolution.resolvedName,
                        using: service,
                        progressTracker: progressTracker,
                        traversalBudget: &traversalBudget
                    )
                }
            }
        }

        clearViewer(for: tab)
        await refresh(server: server, tab: tab)
    }

    func copyEntries(
        _ entries: [RemoteFileEntry],
        from sourceServerId: UUID,
        to destinationDirectoryPath: String,
        destinationTab: RemoteFileTab,
        destinationServer: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard destinationTab.serverId == destinationServer.id,
              let sourceServer = server(for: sourceServerId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let uniqueEntries = uniqueTransferEntries(entries)
        guard !uniqueEntries.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        let plans = try await withRemoteFileService(for: sourceServer) { service in
            var traversalBudget = RemoteFileTraversalBudget()
            var plans: [RemoteFileTransferPlanNode] = []
            for entry in uniqueEntries {
                plans.append(try await self.makeRemoteTransferPlan(
                    for: entry,
                    using: service,
                    symlinkPolicy: .resolveFiles,
                    depth: 0,
                    budget: &traversalBudget
                ))
            }
            return plans
        }
        let progressTracker = TransferProgressTracker(
            totalUnitCount: plans.reduce(0) { $0 + $1.unitCount },
            onProgress: onProgress
        )

        try await withRemoteFileService(for: sourceServer) { sourceService in
            try await self.withRemoteFileService(for: destinationServer) { destinationService in
                var byteBudget = RemoteFileTransferByteBudget()
                let destinationCapacity = try await destinationService.fileSystemCapacity(
                    at: destinationDirectory
                )
                if let reportedBytes = try self.reportedByteCount(for: plans) {
                    var reportedBudget = RemoteFileTransferByteBudget()
                    try reportedBudget.record(reportedBytes)
                    try reportedBudget.validateUploadCapacity(destinationCapacity)
                }
                for plan in plans {
                    try await self.copyRemoteTransferPlan(
                        plan,
                        to: destinationDirectory,
                        operationRootPath: destinationDirectory,
                        sourceService: sourceService,
                        destinationService: destinationService,
                        progressTracker: progressTracker,
                        destinationCapacity: destinationCapacity,
                        byteBudget: &byteBudget
                    )
                }
            }
        }

        clearViewer(for: destinationTab)
        await refresh(server: destinationServer, tab: destinationTab)
    }

    func downloadFile(
        at remotePath: String,
        to localURL: URL,
        server: Server
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            let entry = try await service.stat(at: remotePath)
            guard entry.type != .directory else {
                throw RemoteFileBrowserError.failed(
                    String(localized: "Select a destination folder to download a folder.")
                )
            }
            var byteBudget = RemoteFileTransferByteBudget()
            let limit = try self.downloadLimit(
                reportedBytes: entry.size,
                to: localURL,
                byteBudget: byteBudget
            )
            let downloadedBytes = try await self.downloadFileAtomically(
                at: remotePath,
                to: localURL,
                maxBytes: limit,
                using: service
            )
            try byteBudget.record(downloadedBytes)
        }
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        server: Server
    ) async throws {
        let destinationExisted = FileManager.default.fileExists(atPath: localURL.path)
        do {
            try await withRemoteFileService(for: server) { service in
                var traversalBudget = RemoteFileTraversalBudget()
                let plan = try await self.makeRemoteTransferPlan(
                    for: entry,
                    using: service,
                    symlinkPolicy: .resolveFiles,
                    depth: 0,
                    budget: &traversalBudget
                )
                var byteBudget = RemoteFileTransferByteBudget()
                try await self.downloadRemoteTransferPlan(
                    plan,
                    to: localURL,
                    operationRootURL: localURL,
                    using: service,
                    byteBudget: &byteBudget
                )
            }
        } catch {
            if !destinationExisted {
                try? FileManager.default.removeItem(at: localURL)
            }
            throw error
        }
    }

    func listDirectories(
        at path: String,
        server: Server
    ) async throws -> [RemoteFileEntry] {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withRemoteFileService(for: server) { service in
            try await service.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        return entries
            .filter { $0.type == .directory }
            .sortedForBrowser(using: .name, direction: .ascending)
    }

    func performMutation(
        in tab: RemoteFileTab,
        server: Server,
        operation: @MainActor @escaping @Sendable (any RemoteFileService) async throws -> Void
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withRemoteFileService(for: server) { service in
            try await operation(service)
        }
        await refresh(server: server, tab: tab)
    }

    func deleteDirectoryRecursively(
        at remotePath: String,
        using service: any RemoteFileService
    ) async throws {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        guard normalizedPath != "/",
              let rootName = normalizedPath.split(separator: "/").last.map(String.init) else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        let root = RemoteFileEntry(
            name: rootName,
            path: normalizedPath,
            type: .directory,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
        var budget = RemoteFileTraversalBudget()
        let plan = try await makeRemoteTransferPlan(
            for: root,
            using: service,
            symlinkPolicy: .preserve,
            depth: 0,
            budget: &budget
        )
        try await deleteRemoteTransferPlan(plan, using: service)
    }

    func localItemInfo(at url: URL) async throws -> LocalUploadItemInfo {
        try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var fileStatus = Darwin.stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &fileStatus)
            }
            guard result == 0 else {
                throw RemoteFileBrowserError.failed(
                    String(localized: "The local file could not be inspected safely.")
                )
            }

            let fileType = fileStatus.st_mode & mode_t(S_IFMT)
            let kind: LocalUploadPlanNode.Kind
            switch fileType {
            case mode_t(S_IFREG):
                guard fileStatus.st_size >= 0 else {
                    throw RemoteFileTransferError.byteCountOverflow
                }
                kind = .regularFile(byteCount: UInt64(fileStatus.st_size))
            case mode_t(S_IFDIR):
                kind = .directory
            default:
                // Symlinks and special files are never followed or uploaded.
                throw RemoteFileBrowserError.failed(
                    String(localized: "Only regular files and folders can be uploaded.")
                )
            }

            return LocalUploadItemInfo(
                name: url.lastPathComponent,
                identity: LocalFileIdentity(
                    device: UInt64(bitPattern: Int64(fileStatus.st_dev)),
                    inode: UInt64(fileStatus.st_ino)
                ),
                kind: kind
            )
        }.value
    }

    func localDirectoryContents(at url: URL, maxEntries: Int) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else {
                throw RemoteFileBrowserError.resourceLimitExceeded
            }
            var contents: [URL] = []
            contents.reserveCapacity(min(maxEntries, 256))
            while let child = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard contents.count < maxEntries else {
                    throw RemoteFileTransferError.directoryEntryLimit(maximum: maxEntries)
                }
                contents.append(child)
            }
            guard !enumerationFailed else {
                throw RemoteFileBrowserError.resourceLimitExceeded
            }
            return contents.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    func makeLocalUploadPlan(
        at localURL: URL,
        depth: Int,
        traversalBudget: inout RemoteFileTraversalBudget,
        byteBudget: inout RemoteFileTransferByteBudget,
        visitedIdentities: inout Set<LocalFileIdentity>
    ) async throws -> LocalUploadPlanNode {
        try Task.checkCancellation()
        try traversalBudget.admit(depth: depth)
        let itemInfo = try await localItemInfo(at: localURL)
        guard visitedIdentities.insert(itemInfo.identity).inserted else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        let name = try RemoteFileLeaf(validating: itemInfo.name).value

        switch itemInfo.kind {
        case .regularFile(let byteCount):
            try byteBudget.record(byteCount)
            return LocalUploadPlanNode(
                sourceURL: localURL,
                name: name,
                identity: itemInfo.identity,
                kind: itemInfo.kind,
                children: []
            )
        case .directory:
            let allowedChildren = try traversalBudget.directoryReadLimit()
            let childURLs = try await localDirectoryContents(
                at: localURL,
                maxEntries: allowedChildren
            )
            var children: [LocalUploadPlanNode] = []
            children.reserveCapacity(childURLs.count)
            for childURL in childURLs {
                children.append(try await makeLocalUploadPlan(
                    at: childURL,
                    depth: depth + 1,
                    traversalBudget: &traversalBudget,
                    byteBudget: &byteBudget,
                    visitedIdentities: &visitedIdentities
                ))
            }
            return LocalUploadPlanNode(
                sourceURL: localURL,
                name: name,
                identity: itemInfo.identity,
                kind: itemInfo.kind,
                children: children
            )
        }
    }

    func uploadLocalTransferPlan(
        _ plan: LocalUploadPlanNode,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        using client: any RemoteFileService,
        progressTracker: TransferProgressTracker? = nil,
        traversalBudget: inout RemoteFileTraversalBudget
    ) async throws {
        try Task.checkCancellation()
        try traversalBudget.checkTime()
        let currentItem = try await localItemInfo(at: plan.sourceURL)
        guard currentItem.identity == plan.identity else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }

        let targetName = remoteName ?? plan.name
        let targetLeaf = try RemoteFileLeaf(validating: targetName)
        let remotePath = RemoteFilePath.appending(targetLeaf, to: remoteDirectoryPath)
        progressTracker?.reportCurrentItem(targetName)

        switch (plan.kind, currentItem.kind) {
        case (.directory, .directory):
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: 0o755,
                using: client
            )
            progressTracker?.advance(currentItemName: targetName)
            for child in plan.children {
                try await uploadLocalTransferPlan(
                    child,
                    to: remotePath,
                    using: client,
                    progressTracker: progressTracker,
                    traversalBudget: &traversalBudget
                )
            }
        case (.regularFile(let plannedBytes), .regularFile(let currentBytes)):
            guard currentBytes == plannedBytes else {
                throw RemoteFileBrowserError.resourceLimitExceeded
            }
            try await client.upload(
                fileAt: plan.sourceURL,
                to: remotePath,
                expectedBytes: plannedBytes,
                permissions: Int32(0o644)
            )
            try Task.checkCancellation()
            progressTracker?.advance(currentItemName: targetName)
        default:
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
    }

    enum TransferSymlinkPolicy: Equatable {
        case preserve
        case resolveFiles
    }

    func makeRemoteTransferPlan(
        for entry: RemoteFileEntry,
        using service: any RemoteFileService,
        symlinkPolicy: TransferSymlinkPolicy,
        depth: Int,
        budget: inout RemoteFileTraversalBudget
    ) async throws -> RemoteFileTransferPlanNode {
        try Task.checkCancellation()
        try budget.admit(depth: depth)
        let safeEntry = try validatedTransferEntry(entry)
        let effectiveEntry: RemoteFileEntry

        if safeEntry.type == .symlink, symlinkPolicy == .resolveFiles {
            let resolved = try await service.stat(at: safeEntry.path)
            guard resolved.type != .directory else {
                throw RemoteFileBrowserError.resourceLimitExceeded
            }
            effectiveEntry = RemoteFileEntry(
                name: safeEntry.name,
                path: safeEntry.path,
                type: resolved.type,
                size: resolved.size,
                modifiedAt: resolved.modifiedAt,
                permissions: resolved.permissions,
                symlinkTarget: safeEntry.symlinkTarget ?? resolved.symlinkTarget
            )
        } else {
            effectiveEntry = safeEntry
        }

        guard effectiveEntry.type == .directory else {
            return RemoteFileTransferPlanNode(entry: effectiveEntry, children: [])
        }

        let allowedChildren = try budget.directoryReadLimit()
        let listedChildren = try await service.listDirectory(
            at: effectiveEntry.path,
            maxEntries: allowedChildren + 1
        )
        guard listedChildren.count <= allowedChildren else {
            throw RemoteFileTransferError.directoryEntryLimit(
                maximum: budget.limits.maxEntriesPerDirectory
            )
        }

        var children: [RemoteFileTransferPlanNode] = []
        children.reserveCapacity(listedChildren.count)
        for child in listedChildren {
            let safeChild = try validatedTransferEntry(child, parentPath: effectiveEntry.path)
            children.append(try await makeRemoteTransferPlan(
                for: safeChild,
                using: service,
                symlinkPolicy: symlinkPolicy,
                depth: depth + 1,
                budget: &budget
            ))
        }
        return RemoteFileTransferPlanNode(entry: effectiveEntry, children: children)
    }

    func downloadRemoteTransferPlan(
        _ plan: RemoteFileTransferPlanNode,
        to localURL: URL,
        operationRootURL: URL,
        using service: any RemoteFileService,
        byteBudget: inout RemoteFileTransferByteBudget
    ) async throws {
        try Task.checkCancellation()
        if plan.entry.type == .directory {
            try await createLocalDirectory(at: localURL)
            for child in plan.children {
                let leaf = try RemoteFileLeaf(validating: child.entry.name)
                let childURL = try RemoteFileLocalPath.descendant(
                    named: leaf,
                    in: localURL,
                    operationRootURL: operationRootURL,
                    isDirectory: child.entry.type == .directory
                )
                try await downloadRemoteTransferPlan(
                    child,
                    to: childURL,
                    operationRootURL: operationRootURL,
                    using: service,
                    byteBudget: &byteBudget
                )
            }
            return
        }

        let limit = try downloadLimit(
            reportedBytes: plan.entry.size,
            to: localURL,
            byteBudget: byteBudget
        )
        let downloadedBytes = try await downloadFileAtomically(
            at: plan.entry.path,
            to: localURL,
            maxBytes: limit,
            using: service
        )
        try byteBudget.record(downloadedBytes)
    }

    func copyRemoteTransferPlan(
        _ plan: RemoteFileTransferPlanNode,
        to remoteDirectoryPath: String,
        operationRootPath: String,
        sourceService: any RemoteFileService,
        destinationService: any RemoteFileService,
        progressTracker: TransferProgressTracker?,
        destinationCapacity: RemoteFileFilesystemCapacity,
        byteBudget: inout RemoteFileTransferByteBudget
    ) async throws {
        try Task.checkCancellation()
        let leaf = try RemoteFileLeaf(validating: plan.entry.name)
        let remotePath = RemoteFilePath.appending(leaf, to: remoteDirectoryPath)
        guard RemoteFilePath.isStrictDescendant(remotePath, of: operationRootPath) else {
            throw RemoteFileBrowserError.destinationEscapedRoot
        }

        if plan.entry.type == .directory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: Int32(plan.entry.permissions ?? 0o755),
                using: destinationService
            )
            progressTracker?.advance(currentItemName: plan.entry.name)
            for child in plan.children {
                try await copyRemoteTransferPlan(
                    child,
                    to: remotePath,
                    operationRootPath: operationRootPath,
                    sourceService: sourceService,
                    destinationService: destinationService,
                    progressTracker: progressTracker,
                    destinationCapacity: destinationCapacity,
                    byteBudget: &byteBudget
                )
            }
            return
        }

        let temporaryURL = try temporaryStorage.makeTransferFileURL(for: plan.entry)
        defer { temporaryStorage.removeItem(at: temporaryURL) }
        let limit = try downloadLimit(
            reportedBytes: plan.entry.size,
            to: temporaryURL,
            byteBudget: byteBudget
        )
        try await sourceService.downloadFile(at: plan.entry.path, to: temporaryURL, maxBytes: limit)
        let downloadedBytes = try downloadedFileSize(at: temporaryURL)
        try byteBudget.record(downloadedBytes)
        try byteBudget.validateUploadCapacity(destinationCapacity)
        try await destinationService.upload(
            fileAt: temporaryURL,
            to: remotePath,
            expectedBytes: downloadedBytes,
            permissions: Int32(plan.entry.permissions ?? 0o644)
        )
        progressTracker?.advance(currentItemName: plan.entry.name)
    }

    func deleteRemoteTransferPlan(
        _ plan: RemoteFileTransferPlanNode,
        using service: any RemoteFileService
    ) async throws {
        for child in plan.children {
            try await deleteRemoteTransferPlan(child, using: service)
        }
        if plan.entry.type == .directory {
            try await service.deleteDirectory(at: plan.entry.path)
        } else {
            try await service.deleteFile(at: plan.entry.path)
        }
    }

    func countRemoteTransferUnits(
        for entries: [RemoteFileEntry],
        using client: any RemoteFileService
    ) async throws -> Int {
        var budget = RemoteFileTraversalBudget()
        var totalUnitCount = 0
        for entry in entries {
            let plan = try await makeRemoteTransferPlan(
                for: entry,
                using: client,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
            totalUnitCount += plan.unitCount
        }
        return max(1, totalUnitCount)
    }

    func countRemoteTransferUnits(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> Int {
        try await countRemoteTransferUnits(for: [entry], using: client)
    }

    func validatedTransferEntry(
        _ entry: RemoteFileEntry,
        parentPath: String? = nil
    ) throws -> RemoteFileEntry {
        let leaf = try RemoteFileLeaf(validating: entry.name)
        let normalizedPath = RemoteFilePath.normalize(entry.path)
        let expectedPath = RemoteFilePath.appending(
            leaf,
            to: parentPath ?? RemoteFilePath.parent(of: normalizedPath)
        )
        guard normalizedPath == expectedPath else {
            throw RemoteFileBrowserError.invalidEntryName
        }
        return RemoteFileEntry(
            name: leaf.value,
            path: normalizedPath,
            type: entry.type,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            permissions: entry.permissions,
            symlinkTarget: entry.symlinkTarget
        )
    }

    func downloadedFileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func downloadFileAtomically(
        at remotePath: String,
        to localURL: URL,
        maxBytes: UInt64,
        using service: any RemoteFileService
    ) async throws -> UInt64 {
        let fileManager = FileManager.default
        let stagingURL = localURL.deletingLastPathComponent().appendingPathComponent(
            ".vvterm-download-\(UUID().uuidString).partial",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        try await service.downloadFile(at: remotePath, to: stagingURL, maxBytes: maxBytes)
        let downloadedBytes = try downloadedFileSize(at: stagingURL)

        if fileManager.fileExists(atPath: localURL.path) {
            _ = try fileManager.replaceItemAt(localURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: localURL)
        }
        return downloadedBytes
    }

    func reportedByteCount(for plans: [RemoteFileTransferPlanNode]) throws -> UInt64? {
        var total: UInt64 = 0
        var hasUnknownSize = false

        func add(_ node: RemoteFileTransferPlanNode) throws {
            if node.entry.type != .directory {
                guard let size = node.entry.size else {
                    hasUnknownSize = true
                    return
                }
                let result = total.addingReportingOverflow(size)
                guard !result.overflow else {
                    throw RemoteFileTransferError.byteCountOverflow
                }
                total = result.partialValue
            }
            for child in node.children {
                try add(child)
            }
        }

        for plan in plans {
            try add(plan)
        }
        return hasUnknownSize ? nil : total
    }

    func downloadLimit(
        reportedBytes: UInt64?,
        to localURL: URL,
        byteBudget: RemoteFileTransferByteBudget
    ) throws -> UInt64 {
        try byteBudget.downloadLimit(
            reportedBytes: reportedBytes,
            availableCapacity: availableDownloadCapacity(at: localURL)
        )
    }

    func availableDownloadCapacity(at localURL: URL) throws -> UInt64 {
        let directoryURL = localURL.deletingLastPathComponent()
        let values = try directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let capacity = values.volumeAvailableCapacityForImportantUsage,
           let exactCapacity = UInt64(exactly: capacity) {
            return exactCapacity
        }

        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: directoryURL.path
        )
        guard let capacity = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value else {
            throw RemoteFileBrowserError.resourceLimitExceeded
        }
        return capacity
    }

    func ensureRemoteDirectoryExists(
        at remotePath: String,
        permissions: Int32,
        using client: any RemoteFileService
    ) async throws {
        do {
            let existingEntry = try await client.lstat(at: remotePath)
            guard existingEntry.type == .directory else {
                throw RemoteFileBrowserError.failed(
                    String(
                        format: String(localized: "\"%@\" already exists and is not a folder."),
                        existingEntry.name.isEmpty ? remotePath : existingEntry.name
                    )
                )
            }
        } catch let error as RemoteFileBrowserError {
            guard case .pathNotFound = error else { throw error }
            try await client.createDirectory(at: remotePath, permissions: permissions)
        } catch {
            throw error
        }
    }

    func uniqueTransferEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        var seenPaths: Set<String> = []
        return entries.filter { seenPaths.insert($0.path).inserted }
    }

    func createLocalDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    func withSecurityScopedAccess<T>(
        to urls: [URL],
        operation: () async throws -> T
    ) async throws -> T {
        let accessedURLs = urls.map { url in
            (url: url, accessed: url.startAccessingSecurityScopedResource())
        }
        defer {
            for entry in accessedURLs where entry.accessed {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }
}
