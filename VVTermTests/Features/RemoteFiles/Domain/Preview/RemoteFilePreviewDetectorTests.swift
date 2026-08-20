import Foundation
import Testing
@testable import VVTerm

struct RemoteFilePreviewDetectorTests {
    @Test
    func textPreviewIsDetectedAndDecoded() {
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt")
        let data = Data("hello\nworld".utf8)

        #expect(RemoteFilePreviewDetector.decodeTextPreview(from: data) == "hello\nworld")
    }

    @Test
    func binaryDataIsNotDecodedAsText() {
        let data = Data([0x00, 0xFF, 0x10, 0x80])

        #expect(RemoteFilePreviewDetector.decodeTextPreview(from: data) == nil)
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
