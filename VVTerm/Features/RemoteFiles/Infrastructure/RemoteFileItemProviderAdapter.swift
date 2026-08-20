import Foundation
import UniformTypeIdentifiers

enum RemoteFileItemProviderAdapter {
    static let acceptedTypeIdentifiers = [
        UTType.vvtermRemoteFileEntry.identifier,
        UTType.fileURL.identifier
    ]

    static func acceptsRemoteItems(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.vvtermRemoteFileEntry.identifier) }
    }

    static func acceptsLocalItems(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    static func loadLocalItems(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (Result<[URL], Error>) -> Void
    ) {
        let matchingProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !matchingProviders.isEmpty else { return }

        Task {
            do {
                completion(.success(try await loadLocalURLs(from: matchingProviders)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    static func loadRemotePayloads(from providers: [NSItemProvider]) async throws -> [RemoteFileDragPayload] {
        let matchingProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.vvtermRemoteFileEntry.identifier)
        }
        var payloads: [RemoteFileDragPayload] = []
        payloads.reserveCapacity(matchingProviders.count)

        for provider in matchingProviders {
            payloads.append(try await loadRemotePayload(from: provider))
        }

        guard payloads.contains(where: { !$0.entries.isEmpty }) else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid remote items were dropped."))
        }
        return payloads
    }

    static func makeProvider(
        payload: RemoteFileDragPayload,
        entry: RemoteFileEntry,
        export: @escaping @MainActor @Sendable (RemoteFileEntry) async throws -> URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName(for: payload.entries)
        register(payload: payload, in: provider)
        registerFileRepresentation(for: entry, in: provider, export: export)
        return provider
    }

    private static func register(payload: RemoteFileDragPayload, in provider: NSItemProvider) {
        let encodedPayload = Result { try JSONEncoder().encode(payload) }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier,
            visibility: .ownProcess
        ) { completion in
            do {
                completion(try encodedPayload.get(), nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
    }

    private static func registerFileRepresentation(
        for entry: RemoteFileEntry,
        in provider: NSItemProvider,
        export: @escaping @MainActor @Sendable (RemoteFileEntry) async throws -> URL
    ) {
        provider.registerFileRepresentation(
            forTypeIdentifier: fileTypeIdentifier(for: entry),
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            let exportTask = Task { @MainActor in
                do {
                    let url = try await export(entry)
                    guard !progress.isCancelled else { throw CancellationError() }
                    completion(url, false, nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { exportTask.cancel() }
            return progress
        }
    }

    static func loadLocalURLs(from providers: [NSItemProvider]) async throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(providers.count)
        for provider in providers {
            urls.append(try await loadURL(from: provider))
        }

        let uniqueURLs = Array(NSOrderedSet(array: urls).compactMap { $0 as? URL })
        guard !uniqueURLs.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid files or folders were dropped."))
        }
        return uniqueURLs
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let text = item as? String,
                          let url = URL(string: text) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(
                        throwing: RemoteFileBrowserError.failed(
                            String(localized: "The dropped item could not be resolved to a local file or folder.")
                        )
                    )
                }
            }
        }
    }

    private static func loadRemotePayload(from provider: NSItemProvider) async throws -> RemoteFileDragPayload {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier
            ) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    do {
                        continuation.resume(returning: try JSONDecoder().decode(RemoteFileDragPayload.self, from: data))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(
                        throwing: RemoteFileBrowserError.failed(
                            String(localized: "The dragged remote item could not be decoded.")
                        )
                    )
                }
            }
        }
    }

    static func fileTypeIdentifier(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory else { return UTType.folder.identifier }
        let pathExtension = URL(fileURLWithPath: entry.name).pathExtension
        return UTType(filenameExtension: pathExtension)?.identifier ?? UTType.data.identifier
    }

    private static func suggestedName(for entries: [RemoteFileEntry]) -> String? {
        guard entries.count > 1 else {
            guard let name = entries.first?.name, !name.isEmpty else { return nil }
            return name
        }
        return String(format: String(localized: "%lld items"), Int64(entries.count))
    }
}

extension UTType {
    static let vvtermRemoteFileEntry = UTType(exportedAs: "app.vivy.vvterm.remote-file-entry")
}
