import Foundation
import OSLog

struct RemoteClipboardUpload: Sendable {
    let remotePath: String
    let pastedPathToken: String
    let mimeType: String
    let sizeBytes: Int
}

struct RichPasteUploadResult: Sendable, Equatable {
    let remotePath: String
    let pastedPathToken: String
    let seededRemoteClipboard: Bool
}

enum TerminalRichPasteError: LocalizedError {
    case imageTooLarge(maxBytes: Int)
    case unsupportedRemoteShell
    case remoteTempFileCreationFailed
    case unsafeRemotePath
    case remoteUploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageTooLarge(let maxBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let sizeLabel = formatter.string(fromByteCount: Int64(maxBytes))
            return String(format: String(localized: "Clipboard image is too large. The limit is %@."), sizeLabel)
        case .unsupportedRemoteShell:
            return String(localized: "Rich clipboard paste requires a supported POSIX, PowerShell, or cmd shell.")
        case .remoteTempFileCreationFailed:
            return String(localized: "Remote upload failed: could not create temporary file")
        case .unsafeRemotePath:
            return String(localized: "Remote upload failed: the temporary path cannot be inserted safely in this shell")
        case .remoteUploadFailed(let message):
            return String(format: String(localized: "Remote upload failed: %@"), message)
        }
    }
}

private enum RemoteClipboardSeedCapability: Sendable {
    case unavailable
    case wayland
    case x11
    case macOS
}

actor TerminalRichPasteCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "TerminalRichPasteCoordinator")
    private let sessionId: UUID
    private let transferService: RemoteClipboardTransferService
    private var remoteClipboardCapabilities: [ObjectIdentifier: RemoteClipboardSeedCapability] = [:]

    init(sessionId: UUID) {
        self.sessionId = sessionId
        self.transferService = RemoteClipboardTransferService(sessionId: sessionId)
    }

    func performRichPaste(
        image: ClipboardImagePayload,
        settings: RichClipboardSettings,
        sshClient: SSHClient
    ) async throws -> RichPasteUploadResult {
        logger.info(
            "Perform rich paste [session: \(self.sessionId.uuidString, privacy: .public)] [bytes: \(image.sizeBytes)]"
        )
        guard image.sizeBytes <= settings.maximumImageBytes else {
            throw TerminalRichPasteError.imageTooLarge(maxBytes: settings.maximumImageBytes)
        }

        let upload = try await transferService.uploadImage(image, using: sshClient)
        logger.info(
            "Attempting remote clipboard seeding [session: \(self.sessionId.uuidString, privacy: .public)] [path: \(upload.remotePath, privacy: .private(mask: .hash))]"
        )
        let seededRemoteClipboard = await seedRemoteClipboardIfSupported(upload: upload, sshClient: sshClient)

        return RichPasteUploadResult(
            remotePath: upload.remotePath,
            pastedPathToken: upload.pastedPathToken,
            seededRemoteClipboard: seededRemoteClipboard
        )
    }

    private func seedRemoteClipboardIfSupported(
        upload: RemoteClipboardUpload,
        sshClient: SSHClient
    ) async -> Bool {
        let capability = await remoteClipboardSeedCapability(using: sshClient)
        logger.info(
            "Remote clipboard seed capability [session: \(self.sessionId.uuidString, privacy: .public)] [capability: \(String(describing: capability), privacy: .public)]"
        )
        guard let clipboardCommand = remoteClipboardCommand(for: capability, upload: upload) else {
            return false
        }

        let sentinel = "__vvterm_clipboard_seeded__"
        let wrappedCommand = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            "if \(clipboardCommand) >/dev/null 2>&1; then printf '%s' \(RemoteTerminalBootstrap.shellQuoted(sentinel)); fi"
        )

        do {
            let output = try await sshClient.execute(
                wrappedCommand,
                timeout: .seconds(3)
            )
            return output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == sentinel
        } catch {
            logger.warning(
                "Remote clipboard seeding failed [session: \(self.sessionId.uuidString, privacy: .public)] [error: \(LogPrivacy.errorClass(error), privacy: .public)]"
            )
            return false
        }
    }

    private func remoteClipboardSeedCapability(using sshClient: SSHClient) async -> RemoteClipboardSeedCapability {
        let capabilityKey = ObjectIdentifier(sshClient)
        if let cachedCapability = remoteClipboardCapabilities[capabilityKey] {
            return cachedCapability
        }

        let environment = await sshClient.remoteEnvironment()
        let capability: RemoteClipboardSeedCapability
        switch environment.platform {
        case .linux, .freebsd, .openbsd, .netbsd:
            capability = await probeUnixClipboardCapability(using: sshClient)
        case .darwin:
            capability = await probeDarwinClipboardCapability(using: sshClient)
        case .windows, .unknown:
            capability = .unavailable
        }

        remoteClipboardCapabilities[capabilityKey] = capability
        logger.info(
            "Resolved remote clipboard capability [session: \(self.sessionId.uuidString, privacy: .public)] [capability: \(String(describing: capability), privacy: .public)]"
        )
        return capability
    }

    private func probeUnixClipboardCapability(using sshClient: SSHClient) async -> RemoteClipboardSeedCapability {
        let command = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            """
            if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
              printf '%s' wayland
            elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
              printf '%s' x11
            else
              printf '%s' unsupported
            fi
            """
        )

        do {
            let output = try await sshClient.execute(command)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            switch output {
            case "wayland":
                return .wayland
            case "x11":
                return .x11
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    private func probeDarwinClipboardCapability(using sshClient: SSHClient) async -> RemoteClipboardSeedCapability {
        let command = RemoteTerminalBootstrap.wrapPOSIXShellCommand(
            """
            if command -v osascript >/dev/null 2>&1 && launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
              printf '%s' darwin
            else
              printf '%s' unsupported
            fi
            """
        )

        do {
            let output = try await sshClient.execute(command)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return output == "darwin" ? .macOS : .unavailable
        } catch {
            return .unavailable
        }
    }

    private func remoteClipboardCommand(
        for capability: RemoteClipboardSeedCapability,
        upload: RemoteClipboardUpload
    ) -> String? {
        let quotedPath = RemoteTerminalBootstrap.shellQuoted(upload.remotePath)

        switch capability {
        case .unavailable:
            return nil
        case .wayland:
            return "wl-copy < \(quotedPath)"
        case .x11:
            let mimeType = RemoteTerminalBootstrap.shellQuoted(upload.mimeType)
            return "xclip -selection clipboard -t \(mimeType) -i \(quotedPath)"
        case .macOS:
            let escapedPath = upload.remotePath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let scriptLines = [
                #"set imageFile to POSIX file "\#(escapedPath)""#,
                #"set the clipboard to (read imageFile as picture)"#
            ]
            let quotedLines = scriptLines
                .map { " -e \(RemoteTerminalBootstrap.shellQuoted($0))" }
                .joined()
            return "osascript\(quotedLines)"
        }
    }
}
