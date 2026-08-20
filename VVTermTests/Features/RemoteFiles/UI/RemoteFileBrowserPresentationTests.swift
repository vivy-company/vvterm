import Testing
@testable import VVTerm

@MainActor
struct RemoteFileBrowserPresentationTests {
    @Test
    func routesUseStablePresentationIdentity() {
        #expect(RemoteFileBrowserPresentation.upload(destinationPath: "/home").id == .upload)
        #expect(RemoteFileBrowserPresentation.createFolder(.init(destinationPath: "/home")).id == .createFolder)
        #expect(RemoteFileBrowserPresentation.operationError("failed").id == .operationError)
    }

    @Test
    func newDraftsStartWithCleanTransientState() {
        let createFolder = RemoteFileBrowserPresentation.CreateFolderDraft(destinationPath: "/home")
        #expect(createFolder.name.isEmpty)
        #expect(!createFolder.isSubmitting)

        let entry = makeEntry(permissions: 0o640)
        let permissions = RemoteFileBrowserPresentation.PermissionDraft(
            entry: entry,
            permissions: RemoteFilePermissionDraft(entry: entry),
            originalAccessBits: 0o640,
            preservedBits: 0,
            fileTypeBits: 0
        )
        #expect(!permissions.isSubmitting)
        #expect(permissions.errorMessage == nil)
    }

    @Test
    func platformRoutesRemainExplicit() {
        let upload = RemoteFileBrowserPresentation.upload(destinationPath: "/home")
        #expect(upload.isIOSSheet)
        #expect(!upload.isMacOSSheet)

        let move = RemoteFileBrowserPresentation.move(.init(
            entry: makeEntry(),
            destinationDirectory: "/tmp"
        ))
        #expect(move.isIOSSheet)
        #expect(move.isMacOSSheet)
        #expect(!move.isAlert)
    }

    private func makeEntry(permissions: UInt32? = nil) -> RemoteFileEntry {
        RemoteFileEntry(
            name: "notes.txt",
            path: "/home/notes.txt",
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: permissions,
            symlinkTarget: nil
        )
    }
}
