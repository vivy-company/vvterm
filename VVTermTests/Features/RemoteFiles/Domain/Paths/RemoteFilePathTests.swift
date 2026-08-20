import Foundation
import Testing
@testable import VVTerm

struct RemoteFilePathTests {
    @Test
    func normalizeResolvesRelativeAndParentComponents() {
        let normalized = RemoteFilePath.normalize("../logs/./today.log", relativeTo: "/var/tmp/cache")

        #expect(normalized == "/var/tmp/logs/today.log")
    }

    @Test
    func parentOfRootStaysAtRoot() {
        #expect(RemoteFilePath.parent(of: "/") == "/")
    }

    @Test
    func breadcrumbsIncludeRootAndEveryPathSegment() {
        let breadcrumbs = RemoteFilePath.breadcrumbs(for: "/Users/demo/project")

        #expect(breadcrumbs.map(\.title) == ["/", "Users", "demo", "project"])
        #expect(breadcrumbs.map(\.path) == ["/", "/Users", "/Users/demo", "/Users/demo/project"])
    }

    @Test(arguments: [
        "",
        ".",
        "..",
        "nested/file",
        "nested\\file",
        "/absolute",
        "C:escape",
        "line\nbreak",
        "nul\0byte"
    ])
    func remoteLeafRejectsUnsafeNames(_ value: String) {
        #expect(throws: RemoteFileBrowserError.self) {
            try RemoteFileLeaf(validating: value)
        }
    }

    @Test(arguments: ["notes.txt", ".env", "ユニコード.txt", "e\u{301}.txt", " spaced name "])
    func remoteLeafPreservesValidNames(_ value: String) throws {
        #expect(try RemoteFileLeaf(validating: value).value == value)
    }

    @Test
    func pathPolicyTrimsAValidName() throws {
        #expect(try RemoteFilePathPolicy.validatedName("  notes.txt \n") == "notes.txt")
    }

    @Test(arguments: ["", "   ", ".", "..", "nested/file", "nested\\file"])
    func pathPolicyRejectsInvalidNames(_ value: String) {
        #expect(throws: RemoteFileBrowserError.self) {
            try RemoteFilePathPolicy.validatedName(value)
        }
    }

    @Test
    func pathPolicyResolvesRelativeDestinationDirectory() throws {
        let path = try RemoteFilePathPolicy.validatedDirectoryPath("../archive", relativeTo: "/srv/current")

        #expect(path == "/srv/archive")
    }

    @Test
    func localDescendantRejectsParentSymlinkOutsideRoot() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        defer { try? fileManager.removeItem(at: base) }

        #expect(throws: RemoteFileBrowserError.self) {
            try RemoteFileLocalPath.descendant(
                named: RemoteFileLeaf(validating: "escape.txt"),
                in: linkedParent,
                operationRootURL: root,
                isDirectory: false
            )
        }
    }
}
