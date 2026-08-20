import Foundation

nonisolated enum RemoteFileBrowserError: LocalizedError, Identifiable, Equatable, Sendable {
    case permissionDenied
    case pathNotFound
    case disconnected
    case hostKeyApprovalRequired
    case unsupportedEncoding
    case invalidEntryName
    case destinationEscapedRoot
    case resourceLimitExceeded
    case failed(String)

    var id: String {
        switch self {
        case .permissionDenied:
            return "permissionDenied"
        case .pathNotFound:
            return "pathNotFound"
        case .disconnected:
            return "disconnected"
        case .hostKeyApprovalRequired:
            return "hostKeyApprovalRequired"
        case .unsupportedEncoding:
            return "unsupportedEncoding"
        case .invalidEntryName:
            return "invalidEntryName"
        case .destinationEscapedRoot:
            return "destinationEscapedRoot"
        case .resourceLimitExceeded:
            return "resourceLimitExceeded"
        case .failed(let message):
            return "failed:\(message)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Permission denied.")
        case .pathNotFound:
            return String(localized: "The remote path could not be found.")
        case .disconnected:
            return String(localized: "The remote connection was interrupted.")
        case .hostKeyApprovalRequired:
            return SSHError.hostKeyApprovalRequired.localizedDescription
        case .unsupportedEncoding:
            return String(localized: "Inline preview is unavailable for this file.")
        case .invalidEntryName:
            return String(localized: "The server returned an unsafe file name.")
        case .destinationEscapedRoot:
            return String(localized: "The file destination is outside the selected folder.")
        case .resourceLimitExceeded:
            return String(localized: "The remote file operation exceeded its safety limit.")
        case .failed(let message):
            return message
        }
    }

    static func map(_ error: Error) -> RemoteFileBrowserError {
        if let browserError = error as? RemoteFileBrowserError {
            return browserError
        }
        if let sshError = error as? SSHError,
           case .hostKeyApprovalRequired = sshError {
            return .hostKeyApprovalRequired
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = message.lowercased()

        if lowercased.contains("permission denied") || lowercased.contains("ssh_fx_permission_denied") {
            return .permissionDenied
        }
        if lowercased.contains("not found") || lowercased.contains("no such file") || lowercased.contains("ssh_fx_no_such_file") {
            return .pathNotFound
        }
        if lowercased.contains("not connected") || lowercased.contains("timed out") || lowercased.contains("timeout") || lowercased.contains("disconnect") {
            return .disconnected
        }

        return .failed(message.isEmpty ? String(localized: "The file browser request failed.") : message)
    }
}
