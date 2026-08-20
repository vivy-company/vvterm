import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileConflictResolverTests {
    @Test
    func keepBothGeneratesNumberedNameForConflictingFile() async throws {
        let resolver = RemoteFileConflictResolver()
        var reservedNames: Set<String> = []
        let existing = makeEntry(name: "report.txt", path: "/remote/report.txt")
        let service = FakeRemoteFileService(existingPaths: [
            "/remote/report.txt": existing,
            "/remote/report 2.txt": makeEntry(name: "report 2.txt", path: "/remote/report 2.txt")
        ])

        let resolution = try await resolver.resolveName(
            for: "report.txt",
            in: "/remote",
            policy: .keepBoth,
            using: service,
            reservedNames: &reservedNames
        )

        #expect(resolution.originalName == "report.txt")
        #expect(resolution.existingEntry == existing)
        #expect(resolution.resolvedName == "report 3.txt")
    }

    @Test
    func replaceExistingKeepsOriginalNameWhenConflictExists() async throws {
        let resolver = RemoteFileConflictResolver()
        var reservedNames: Set<String> = []
        let existing = makeEntry(name: "report.txt", path: "/remote/report.txt")
        let service = FakeRemoteFileService(existingPaths: [existing.path: existing])

        let resolution = try await resolver.resolveName(
            for: "report.txt",
            in: "/remote",
            policy: .replaceExisting,
            using: service,
            reservedNames: &reservedNames
        )

        #expect(resolution.existingEntry == existing)
        #expect(resolution.resolvedName == "report.txt")
    }

    @Test
    func noConflictReturnsOriginalNameAndNilExistingEntry() async throws {
        let resolver = RemoteFileConflictResolver()
        var reservedNames: Set<String> = []
        let service = FakeRemoteFileService(existingPaths: [:])

        let resolution = try await resolver.resolveName(
            for: "fresh.txt",
            in: "/remote",
            policy: .keepBoth,
            using: service,
            reservedNames: &reservedNames
        )

        #expect(resolution.existingEntry == nil)
        #expect(resolution.resolvedName == "fresh.txt")
    }

    private func makeEntry(name: String, path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}

private struct FakeRemoteFileService: RemoteFileService {
    let existingPaths: [String: RemoteFileEntry]

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] {
        []
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        try await lstat(at: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        guard let entry = existingPaths[path] else {
            throw RemoteFileBrowserError.pathNotFound
        }
        return entry
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        Data()
    }

    func downloadFile(at path: String, to localURL: URL, maxBytes: UInt64) async throws {}

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func upload(
        fileAt localURL: URL,
        to remotePath: String,
        expectedBytes: UInt64,
        permissions: Int32
    ) async throws {}

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {}

    func deleteDirectory(at path: String) async throws {}

    func setPermissions(at path: String, permissions: UInt32) async throws {}

    func resolveHomeDirectory() async throws -> String {
        "/"
    }

    func fileSystemCapacity(at path: String) async throws -> RemoteFileFilesystemCapacity {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }
}
