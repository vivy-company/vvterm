import Foundation
import Testing
@testable import VVTerm

struct RemoteFileSortTests {
    @Test
    func directoriesStayAheadOfFilesWhenSortingByName() {
        let entries = [
            makeEntry(name: "zeta.txt", path: "/tmp/zeta.txt", type: .file, size: 20, modifiedAt: Date(timeIntervalSince1970: 10)),
            makeEntry(name: "alpha", path: "/tmp/alpha", type: .directory, size: nil, modifiedAt: Date(timeIntervalSince1970: 5)),
            makeEntry(name: "beta.txt", path: "/tmp/beta.txt", type: .file, size: 10, modifiedAt: Date(timeIntervalSince1970: 20))
        ]

        let sorted = entries.sortedForBrowser(using: .name, direction: .ascending)

        #expect(sorted.map(\.name) == ["alpha", "beta.txt", "zeta.txt"])
    }

    @Test
    func sizeSortUsesDirectionWithinSameType() {
        let entries = [
            makeEntry(name: "small.txt", path: "/tmp/small.txt", type: .file, size: 10, modifiedAt: nil),
            makeEntry(name: "large.txt", path: "/tmp/large.txt", type: .file, size: 90, modifiedAt: nil),
            makeEntry(name: "medium.txt", path: "/tmp/medium.txt", type: .file, size: 50, modifiedAt: nil)
        ]

        let sorted = entries.sortedForBrowser(using: .size, direction: .descending)

        #expect(sorted.map(\.name) == ["large.txt", "medium.txt", "small.txt"])
    }

    private func makeEntry(
        name: String,
        path: String,
        type: RemoteFileType,
        size: UInt64?,
        modifiedAt: Date?
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: size,
            modifiedAt: modifiedAt,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}
