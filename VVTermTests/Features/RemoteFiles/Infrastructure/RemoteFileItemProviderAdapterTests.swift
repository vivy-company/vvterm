import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VVTerm

@MainActor
struct RemoteFileItemProviderAdapterTests {
    @Test
    func decodesRemotePayloadOutsideSwiftUI() async throws {
        let entry = makeEntry()
        let payload = RemoteFileDragPayload(serverId: UUID(), entries: [entry])
        let data = try JSONEncoder().encode(payload)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }

        let decoded = try await RemoteFileItemProviderAdapter.loadRemotePayloads(from: [provider])

        #expect(decoded == [payload])
    }

    @Test
    func decodesAndDeduplicatesLocalFileURLs() async throws {
        let url = URL(fileURLWithPath: "/tmp/vvterm-drop.txt")
        let providers = [NSItemProvider(contentsOf: url), NSItemProvider(contentsOf: url)].compactMap { $0 }

        let decoded = try await RemoteFileItemProviderAdapter.loadLocalURLs(from: providers)

        #expect(decoded == [url])
    }

    @Test
    func fileTypeUsesFolderAndFilenameExtension() {
        #expect(RemoteFileItemProviderAdapter.fileTypeIdentifier(for: makeEntry(type: .directory)) == UTType.folder.identifier)
        #expect(RemoteFileItemProviderAdapter.fileTypeIdentifier(for: makeEntry()).contains("plain-text"))
    }

    private func makeEntry(type: RemoteFileType = .file) -> RemoteFileEntry {
        RemoteFileEntry(
            name: "notes.txt",
            path: "/home/notes.txt",
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}
