import Combine
import Foundation
import os.log

extension RemoteFileBrowserStore {
    func loadPreview(
        for entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server,
        allowLargeDownloads: Bool = false
    ) async {
        guard tab.serverId == server.id else { return }
        guard entry.supportsPreview else { return }

        let currentState = state(for: tab)
        if currentState.isLoadingViewer, currentState.selectedEntryPath == entry.path {
            return
        }
        if currentState.viewerPayload?.entry.path == entry.path,
           currentState.viewerPayload?.previewKind != .unavailable,
           !(currentState.viewerPayload?.requiresExplicitDownload == true && allowLargeDownloads) {
            return
        }

        if let fileSize = entry.size,
           fileSize > UInt64(Self.previewConfirmationBytes),
           !allowLargeDownloads {
            cleanupPreviewArtifact(for: currentState.viewerPayload)
            let payload = RemoteFileViewerPayload(
                previewKind: .unavailable,
                entry: entry,
                textPreview: nil,
                previewFileURL: nil,
                isTruncated: false,
                unavailableMessage: String(
                    localized: "This file is larger than 1 MB. Download it first if you want to preview it."
                ),
                requiresExplicitDownload: true,
                previewByteCount: fileSize
            )
            updateState(for: tab) { state in
                state.viewerPhase = .loaded(payload)
            }
            return
        }

        let requestID = UUID()
        cleanupPreviewArtifact(for: currentState.viewerPayload)

        updateState(for: tab) { state in
            state.viewerPhase.beginLoading(path: entry.path, requestID: requestID)
        }

        do {
            let readLimit = Int(min(
                entry.size ?? UInt64(Self.defaultPreviewBytes),
                UInt64(Self.hardPreviewBytes)
            ))
            let effectiveReadLimit = max(Self.defaultPreviewBytes, readLimit)
            let data = try await withRemoteFileService(for: server) { service in
                try await service.readFile(at: entry.path, maxBytes: effectiveReadLimit)
            }

            guard state(for: tab).viewerPhase.isLoading(requestID: requestID) else { return }

            let previewData = data.prefix(Self.defaultPreviewBytes)
            let isTruncated = (entry.size.map { $0 > UInt64(Self.defaultPreviewBytes) } ?? false)
                || data.count > Self.defaultPreviewBytes
                || data.count >= Self.hardPreviewBytes
            let previewKind = previewLoader.previewKind(for: entry, data: previewData)
            let payload: RemoteFileViewerPayload

            switch previewKind {
            case .text:
                payload = RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: entry,
                    textPreview: previewLoader.decodeTextPreview(from: previewData),
                    previewFileURL: nil,
                    isTruncated: isTruncated,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            case .image, .video:
                let previewFileURL: URL?
                let unavailableMessage: String?
                var previewByteCount = entry.size

                if let fileSize = entry.size, fileSize > UInt64(Self.maxMediaPreviewBytes) {
                    previewFileURL = nil
                    unavailableMessage = String(
                        localized: "This file is too large to preview inline. Download it to inspect the full contents."
                    )
                } else {
                    let tempURL = try makePreviewFileURL(for: entry)
                    do {
                        try await withRemoteFileService(for: server) { service in
                            try await service.downloadFile(
                                at: entry.path,
                                to: tempURL,
                                maxBytes: UInt64(Self.maxMediaPreviewBytes)
                            )
                        }
                        previewByteCount = try downloadedFileSize(at: tempURL)
                        let passedValidation = await validateDownloadedPreview(
                            at: tempURL,
                            kind: previewKind
                        )
                        previewFileURL = validatedPreviewURL(
                            at: tempURL,
                            passedValidation: passedValidation
                        )
                        if previewFileURL != nil {
                            unavailableMessage = nil
                        } else {
                            unavailableMessage = String(
                                localized: "This file downloaded successfully, but macOS could not open it for inline preview."
                            )
                        }
                    } catch {
                        temporaryStorage.removeItem(at: tempURL)
                        throw error
                    }
                }

                payload = RemoteFileViewerPayload(
                    previewKind: previewFileURL == nil ? .unavailable : previewKind,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: previewFileURL,
                    isTruncated: false,
                    unavailableMessage: unavailableMessage,
                    requiresExplicitDownload: false,
                    previewByteCount: previewByteCount
                )
            case .unavailable:
                payload = RemoteFileViewerPayload(
                    previewKind: .unavailable,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: String(localized: "Inline preview is unavailable for this file."),
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            }

            var didComplete = false
            let stateStillExists = updateExistingState(for: tab) { state in
                didComplete = state.viewerPhase.complete(requestID: requestID, payload: payload)
            }
            if !stateStillExists || !didComplete {
                cleanupPreviewArtifact(for: payload)
            }
        } catch {
            var didFail = false
            guard updateExistingState(for: tab, mutation: { state in
                didFail = state.viewerPhase.fail(
                    requestID: requestID,
                    error: RemoteFileBrowserError.map(error)
                )
            }) else { return }
            guard didFail else { return }
            logger.error("Remote file preview failed [path: \(entry.path, privacy: .private(mask: .hash))] [error: \(LogPrivacy.errorClass(error), privacy: .public)]")
        }
    }

    func clearViewer(for tab: RemoteFileTab) {
        cleanupPreviewArtifact(for: state(for: tab).viewerPayload)
        updateState(for: tab) { state in
            state.viewerPhase = .idle
        }
    }

    func saveTextPreview(
        _ text: String,
        for entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        guard let data = text.data(using: .utf8) else {
            throw RemoteFileBrowserError.unsupportedEncoding
        }

        let updatedEntry = try await withRemoteFileService(for: server) { service in
            let effectivePermissions = Int32(entry.permissions ?? 0o644)
            try await service.upload(data, to: entry.path, permissions: effectivePermissions, strategy: .automatic)
            return try await service.lstat(at: entry.path)
        }

        updateState(for: tab) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path {
                state.viewerPhase = .loaded(RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: updatedEntry,
                    textPreview: text,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: UInt64(data.count)
                ))
            }
        }
    }

    func makePreviewFileURL(for entry: RemoteFileEntry) throws -> URL {
        try temporaryStorage.makePreviewFileURL(for: entry)
    }

    func cleanupPreviewArtifact(for payload: RemoteFileViewerPayload?) {
        temporaryStorage.removePreviewArtifact(for: payload)
    }

    func validateDownloadedPreview(at url: URL, kind: RemoteFilePreviewKind) async -> Bool {
        await previewLoader.validateDownloadedPreview(at: url, kind: kind, logger: logger)
    }

    func validatedPreviewURL(at url: URL, passedValidation: Bool) -> URL? {
        guard passedValidation else {
            temporaryStorage.removeItem(at: url)
            return nil
        }
        return url
    }
}
