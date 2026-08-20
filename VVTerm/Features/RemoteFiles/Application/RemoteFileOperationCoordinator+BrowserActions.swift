import Foundation

extension RemoteFileOperationCoordinator {
    func upload(
        urls: [URL],
        to destinationPath: String,
        initialMessage: String,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server
    ) {
        guard !urls.isEmpty else { return }
        start(
            kind: .upload,
            title: String(localized: "Uploading"),
            initialMessage: initialMessage,
            successMessage: String(localized: "Upload complete.")
        ) { onProgress in
            try await browser.uploadFilesResolvingConflicts(
                at: urls,
                to: destinationPath,
                in: tab,
                server: server,
                onProgress: onProgress
            )
        }
    }

    func transferDroppedItems(
        to destinationPath: String,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        loadPayloads: @escaping @MainActor () async throws -> [RemoteFileDragPayload]
    ) {
        start(
            kind: .transfer,
            title: String(localized: "Transferring"),
            initialMessage: String(localized: "Preparing remote items."),
            successMessage: String(localized: "Transfer complete.")
        ) { onProgress in
            let payloads = try await loadPayloads()
            try await browser.transferDroppedRemoteItems(
                payloads,
                to: destinationPath,
                destinationTab: tab,
                destinationServer: server,
                onProgress: onProgress
            )
        }
    }

    func createFolder(
        named proposedName: String,
        in destinationPath: String,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        onSuccess: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        run(
            operation: {
                let name = try RemoteFilePathPolicy.validatedName(
                    proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try await browser.createDirectory(named: name, in: destinationPath, tab: tab, server: server)
                return RemoteFilePath.appending(name, to: destinationPath)
            },
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }

    func createUniqueFolder(
        in proposedDirectory: String,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        onSuccess: @escaping @MainActor (String, String) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        run(
            operation: {
                let destinationPath = RemoteFilePath.normalize(
                    proposedDirectory,
                    relativeTo: browser.currentPath(for: tab)
                )
                if browser.currentPath(for: tab) != destinationPath {
                    await browser.openBreadcrumb(
                        RemoteFileBreadcrumb(title: "", path: destinationPath),
                        in: tab,
                        server: server
                    )
                }
                let name = uniqueFolderName(in: browser.entries(for: tab))
                try await browser.createDirectory(named: name, in: destinationPath, tab: tab, server: server)
                return (RemoteFilePath.appending(name, to: destinationPath), name)
            },
            onSuccess: { result in onSuccess(result.0, result.1) },
            onFailure: onFailure
        )
    }

    func rename(
        _ entry: RemoteFileEntry,
        to proposedName: String,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        onSuccess: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        run(
            operation: {
                let name = try RemoteFilePathPolicy.validatedName(
                    proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let destinationPath = RemoteFilePath.appending(
                    try RemoteFileLeaf(validating: name),
                    to: RemoteFilePath.parent(of: entry.path)
                )
                guard name != entry.name else { return destinationPath }
                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: tab,
                    server: server
                )
                return destinationPath
            },
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }

    func move(
        _ entry: RemoteFileEntry,
        to proposedDirectory: String,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        run(
            operation: {
                let sourceDirectory = RemoteFilePath.parent(of: entry.path)
                let destinationDirectory = try RemoteFilePathPolicy.validatedDirectoryPath(
                    proposedDirectory,
                    relativeTo: sourceDirectory
                )
                let destinationPath = RemoteFilePath.appending(
                    try RemoteFileLeaf(validating: entry.name),
                    to: destinationDirectory
                )
                guard destinationPath != entry.path else { return }
                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: tab,
                    server: server
                )
            },
            onSuccess: { _ in onSuccess() },
            onFailure: onFailure
        )
    }

    func delete(
        _ entries: [RemoteFileEntry],
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard !entries.isEmpty else { return }
        run(
            operation: {
                for entry in entries {
                    try await browser.deleteItem(
                        at: entry.path,
                        in: tab,
                        server: server,
                        type: entry.type
                    )
                }
            },
            onSuccess: { _ in },
            onFailure: onFailure
        )
    }

    func changePermissions(
        for entry: RemoteFileEntry,
        draft: RemoteFilePermissionDraft,
        preservedBits: UInt32,
        fileTypeBits: UInt32,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let requestedPermissions = fileTypeBits | preservedBits | draft.accessBits
        run(
            operation: {
                try await browser.setPermissions(
                    entry,
                    permissions: requestedPermissions,
                    in: tab,
                    server: server
                )
            },
            onSuccess: { _ in onSuccess() },
            onFailure: onFailure
        )
    }

    func download(
        _ entry: RemoteFileEntry,
        to destinationURL: URL,
        browser: RemoteFileBrowserStore,
        server: Server
    ) {
        start(
            kind: .transfer,
            title: String(localized: "Downloading"),
            initialMessage: String(localized: "Downloading remote file."),
            successMessage: String(localized: "Download complete."),
            completion: .init(
                fileURL: destinationURL,
                fileName: destinationURL.lastPathComponent,
                filePath: destinationURL.path
            )
        ) { _ in
            try await browser.downloadFile(at: entry.path, to: destinationURL, server: server)
        }
    }

    @discardableResult
    func prepareFile(
        _ entry: RemoteFileEntry,
        purpose: PreparedFilePurpose,
        browser: RemoteFileBrowserStore,
        tab: RemoteFileTab,
        server: Server,
        onPrepared: @escaping @MainActor (PreparedFile) -> Void
    ) -> UUID {
        let id = UUID()
        beginPreparedFileRequest(id, purpose: purpose)
        let box = PreparedFileBox()
        let isExport = purpose == .downloadExport

        start(
            id: id,
            kind: .transfer,
            title: isExport ? String(localized: "Downloading") : String(localized: "Sharing"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: isExport
                ? String(localized: "Download ready to export.")
                : String(localized: "Share sheet ready."),
            keepsSuccessVisible: isExport,
            onSuccess: { [weak self] in
                guard let self, let file = box.file else { return }
                publishPreparedFile(
                    file,
                    cleanup: { browser.removeTemporaryTransferFile(at: file.url, in: tab) },
                    onPrepared: onPrepared
                )
            }
        ) { _ in
            let temporaryURL = try browser.makeTemporaryTransferFileURL(for: entry, in: tab)
            do {
                try await browser.downloadFile(at: entry.path, to: temporaryURL, server: server)
                box.file = PreparedFile(
                    id: id,
                    purpose: purpose,
                    url: temporaryURL,
                    filename: entry.name
                )
            } catch {
                browser.removeTemporaryTransferFile(at: temporaryURL, in: tab)
                throw error
            }
        }
        return id
    }
}

private func uniqueFolderName(in entries: [RemoteFileEntry]) -> String {
    let baseName = String(localized: "Untitled Folder")
    let existingNames = Set(entries.map {
        $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    })
    guard existingNames.contains(
        baseName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    ) else { return baseName }

    for index in 2...10_000 {
        let candidate = "\(baseName) \(index)"
        let folded = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !existingNames.contains(folded) { return candidate }
    }
    return "\(baseName) \(UUID().uuidString.prefix(6))"
}

@MainActor
private final class PreparedFileBox {
    var file: RemoteFileOperationCoordinator.PreparedFile?
}
