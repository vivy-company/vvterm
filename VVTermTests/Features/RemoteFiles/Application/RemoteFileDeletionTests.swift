import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileDeletionTests: RemoteFileTransferTestSupport {
    @Test
    func deleteDirectoryRecursivelyRemovesNestedContentsBeforeParent() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/root/.vivyterm": [
                    makeEntry(name: "cache", path: "/root/.vivyterm/cache", type: .directory),
                    makeEntry(name: "config.json", path: "/root/.vivyterm/config.json", type: .file),
                    makeEntry(name: "current", path: "/root/.vivyterm/current", type: .symlink)
                ],
                "/root/.vivyterm/cache": [
                    makeEntry(name: "index.db", path: "/root/.vivyterm/cache/index.db", type: .file)
                ]
            ]
        )

        try await store.deleteDirectoryRecursively(at: "/root/.vivyterm", using: service)

        #expect(service.operations == [
            .deleteFile("/root/.vivyterm/cache/index.db"),
            .deleteDirectory("/root/.vivyterm/cache"),
            .deleteFile("/root/.vivyterm/config.json"),
            .deleteFile("/root/.vivyterm/current"),
            .deleteDirectory("/root/.vivyterm")
        ])
    }

    @Test
    func transferPlanRejectsChildOutsideListedDirectory() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let root = makeEntry(name: "root", path: "/root", type: .directory)
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/root": [makeEntry(name: "escape.txt", path: "/outside/escape.txt")]
            ]
        )
        var budget = RemoteFileTraversalBudget()

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeRemoteTransferPlan(
                for: root,
                using: service,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
        }
    }

    @Test
    func transferPlanDoesNotFollowDirectorySymlink() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let link = makeEntry(name: "linked", path: "/root/linked", type: .symlink)
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            statEntries: [
                "/root/linked": makeEntry(
                    name: "target",
                    path: "/outside/target",
                    type: .directory
                )
            ]
        )
        var budget = RemoteFileTraversalBudget()

        await #expect(throws: RemoteFileBrowserError.self) {
            try await store.makeRemoteTransferPlan(
                for: link,
                using: service,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
        }
        #expect(service.listedPaths.isEmpty)
    }

    @Test
    func transferPlanEnforcesDepthLimit() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let root = makeEntry(name: "root", path: "/root", type: .directory)
        let child = makeEntry(name: "child", path: "/root/child", type: .directory)
        let grandchild = makeEntry(
            name: "grandchild",
            path: "/root/child/grandchild",
            type: .directory
        )
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/root": [child],
                "/root/child": [grandchild]
            ]
        )
        var budget = RemoteFileTraversalBudget(
            limits: RemoteFileTransferLimits(
                maxDepth: 1,
                maxEntries: 10,
                maxEntriesPerDirectory: 10,
                maxFileBytes: 10,
                maxAggregateBytes: 10,
                maxElapsed: .seconds(10),
                minimumFreeBytes: 2
            )
        )

        await #expect(throws: RemoteFileTransferError.self) {
            try await store.makeRemoteTransferPlan(
                for: root,
                using: service,
                symlinkPolicy: .resolveFiles,
                depth: 0,
                budget: &budget
            )
        }
    }

}

