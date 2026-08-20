import Foundation

enum RemoteFileBrowserPresentation: Identifiable {
    enum ID: Hashable {
        case upload
        case share
        case createFolder
        case rename
        case move
        case delete
        case permissions
        case downloadExport
        case operationError
        case transferCancellation
    }

    struct CreateFolderDraft {
        let destinationPath: String
        var name = ""
        var isSubmitting = false
    }

    struct RenameDraft {
        let entry: RemoteFileEntry
        var name: String
        var isSubmitting = false
    }

    struct MoveDraft {
        let entry: RemoteFileEntry
        var destinationDirectory: String
        var isSubmitting = false
    }

    struct PermissionDraft {
        let entry: RemoteFileEntry
        var permissions: RemoteFilePermissionDraft
        let originalAccessBits: UInt32
        let preservedBits: UInt32
        let fileTypeBits: UInt32
        var isSubmitting = false
        var errorMessage: String?
    }

    struct DownloadExport {
        let document: RemoteFileDownloadDocument
        let filename: String
        let transferID: UUID
    }

    case upload(destinationPath: String)
    case share(RemoteFileShareItem)
    case createFolder(CreateFolderDraft)
    case rename(RenameDraft)
    case move(MoveDraft)
    case delete(RemoteFileEntry)
    case permissions(PermissionDraft)
    case downloadExport(DownloadExport)
    case operationError(String)
    case transferCancellation(RemoteFileTransferCancellationRequest)

    var id: ID {
        switch self {
        case .upload: .upload
        case .share: .share
        case .createFolder: .createFolder
        case .rename: .rename
        case .move: .move
        case .delete: .delete
        case .permissions: .permissions
        case .downloadExport: .downloadExport
        case .operationError: .operationError
        case .transferCancellation: .transferCancellation
        }
    }

    var isAlert: Bool {
        switch self {
        case .operationError, .transferCancellation:
            true
        default:
            false
        }
    }

    var isDownloadExport: Bool {
        if case .downloadExport = self { true } else { false }
    }

    var isIOSSheet: Bool {
        switch self {
        case .upload, .share, .createFolder, .rename, .move, .delete, .permissions:
            true
        default:
            false
        }
    }

    var isMacOSSheet: Bool {
        switch self {
        case .move, .permissions:
            true
        default:
            false
        }
    }
}

enum RemoteFileTransferKind {
    case upload
    case transfer

    var confirmationTitle: String {
        switch self {
        case .upload:
            String(localized: "Cancel Upload?")
        case .transfer:
            String(localized: "Cancel Transfer?")
        }
    }

    var cancelButtonTitle: String {
        switch self {
        case .upload:
            String(localized: "Cancel Upload")
        case .transfer:
            String(localized: "Cancel Transfer")
        }
    }

    var keepButtonTitle: String {
        switch self {
        case .upload:
            String(localized: "Keep Uploading")
        case .transfer:
            String(localized: "Continue Transfer")
        }
    }

    var confirmationMessage: String {
        switch self {
        case .upload:
            String(localized: "The current upload will stop.")
        case .transfer:
            String(localized: "The current file transfer will stop.")
        }
    }
}

struct RemoteFileTransferCancellationRequest: Identifiable {
    let id: UUID
    let kind: RemoteFileTransferKind
}
