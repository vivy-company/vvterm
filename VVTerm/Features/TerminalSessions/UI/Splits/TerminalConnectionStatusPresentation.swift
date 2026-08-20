import Foundation

extension TerminalTabOpeningError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .alreadyOpening:
            return String(
                format: String(localized: "Connection failed: %@"),
                String(localized: "A tab is already opening for this server.")
            )
        }
    }
}

nonisolated enum TerminalConnectionFailurePresentation {
    static func message(for failure: TerminalConnectionFailure) -> String {
        switch failure {
        case .reconnectTimedOut:
            return String(localized: "Connection timed out. Please retry.")
        case .tmuxStartupFailed:
            return String(localized: "Unable to start tmux session.")
        case .eternalTerminal(let failure, let host, let port):
            return eternalTerminalMessage(for: failure, host: host, port: port)
        case .external(let message, _, _):
            return message
        }
    }

    static func ansiSSHErrorData(for failure: TerminalConnectionFailure) -> Data? {
        let line = "\r\n\u{001B}[31mSSH Error: \(message(for: failure))\u{001B}[0m\r\n"
        return line.data(using: .utf8)
    }

    private static func eternalTerminalMessage(
        for failure: EternalTerminalSessionFailure,
        host: String,
        port: Int
    ) -> String {
        switch failure {
        case .bootstrapSSH:
            return String(localized: "Eternal Terminal could not start through SSH. Verify the SSH credentials and that etterminal is installed on the host.")
        case .bootstrapResponse(let excerpt):
            let excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if excerpt.contains("VVTERM_ET_UNSUPPORTED_NATIVE_WINDOWS") {
                return String(localized: "Eternal Terminal does not run as a native Windows PowerShell or Command Prompt service. Configure this SSH connection to open inside WSL with Eternal Terminal installed, or use SSH with psmux instead.")
            }
            if excerpt.contains("VVTERM_ET_REQUIRES_POSIX_SHELL") {
                return String(localized: "Eternal Terminal requires a POSIX login shell with /bin/sh. Configure this SSH connection to open a supported Linux, macOS, BSD, or WSL environment, then try again.")
            }
            if excerpt.localizedCaseInsensitiveContains("communicating with et daemon") {
                return String(localized: "Eternal Terminal is installed, but its server daemon is not running or uses a different socket. On Linux, run “sudo systemctl enable --now et”. On macOS with Homebrew, run “brew services start et”. Then try again. If it still fails, ensure etterminal and etserver use the same server FIFO.")
            }
            guard !excerpt.isEmpty else {
                return String(localized: "etterminal did not return valid connection details. Verify the Eternal Terminal installation on the host.")
            }
            return String(
                format: String(localized: "etterminal did not return valid connection details. Host response: %@"),
                excerpt
            )
        case .malformedBootstrapCredentials:
            return String(localized: "etterminal returned malformed connection details. Update Eternal Terminal on the host and try again.")
        case .resumeState(let message, _):
            return message
        case .transport:
            return String(
                format: String(localized: "Could not reach etserver at %@:%d. Verify etserver is running and TCP port %d is open."),
                host,
                port,
                port
            )
        case .invalidKey:
            return String(localized: "etserver rejected the session key. Reconnect to start a new Eternal Terminal session.")
        case .protocolMismatch:
            return String(localized: "The Eternal Terminal client and server protocol versions do not match. Update Eternal Terminal on the host.")
        case .disconnectedBufferFull:
            return String(localized: "Eternal Terminal could not buffer more input while offline. Reconnect and try again.")
        case .connectionInProgress:
            return String(localized: "An Eternal Terminal connection is already starting.")
        case .connectionClosed:
            return String(localized: "The Eternal Terminal session closed. Reconnect to start a new session.")
        case .applicationSuspended:
            return String(localized: "Eternal Terminal input is paused while VVTerm is in the background.")
        case .sessionUnrecoverable:
            return String(localized: "The Eternal Terminal session can no longer recover. Reconnect to start a new session.")
        case .client:
            return String(localized: "Eternal Terminal could not establish the session. Verify the server installation and try again.")
        case .unknown:
            return String(localized: "Eternal Terminal could not connect. Verify etserver is running and the configured ET port is reachable.")
        }
    }
}

extension TerminalDisconnectReason {
    var statusMessage: String? {
        switch self {
        case .transportEnded:
            return nil
        case .tmuxDetached:
            return String(localized: "tmux session is still running on the server.")
        case .externalTmuxEnded:
            return String(localized: "The tmux session has ended.")
        }
    }
}

enum TerminalConnectionStatusPresentation: Hashable {
    case hidden
    case connecting(serverName: String)
    case disconnected(message: String?)
    case failed(message: String, allowsHostKeyReplacement: Bool)

    static func resolve(
        credentialLoadErrorMessage: String?,
        connectionState: ConnectionState,
        serverName: String,
        hasEstablishedConnection: Bool,
        automaticReconnectAllowed: Bool,
        isReconnectPreparationInFlight: Bool,
        isAwaitingTmuxSelection: Bool,
        terminalExists: Bool,
        isReady: Bool,
        disconnectedMessage: String?
    ) -> Self {
        if let credentialLoadErrorMessage {
            return .failed(
                message: credentialLoadErrorMessage,
                allowsHostKeyReplacement: false
            )
        }

        if isAwaitingTmuxSelection {
            return .hidden
        }

        if TerminalConnectionPresentationPolicy.usesReconnectBanner(
            connectionState: connectionState,
            hasEstablishedConnection: hasEstablishedConnection,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: isReconnectPreparationInFlight
        ) {
            return .hidden
        }

        switch connectionState {
        case .connecting:
            return .connecting(serverName: serverName)
        case .reconnecting:
            return .hidden
        case .disconnected:
            return .disconnected(message: disconnectedMessage)
        case .failed(let failure):
            return .failed(
                message: TerminalConnectionFailurePresentation.message(for: failure),
                allowsHostKeyReplacement: failure.requiredAction == .approveHostKey
            )
        case .connected, .idle:
            return !isReady && !terminalExists ? .connecting(serverName: serverName) : .hidden
        }
    }
}

struct TerminalConnectionStatusPresentationIdentity: Hashable {
    let presentation: TerminalConnectionStatusPresentation
    let connectionAttemptID: UUID
}

enum TerminalConnectionStatusDismissalPolicy {
    static func identity(
        for presentation: TerminalConnectionStatusPresentation,
        connectionAttemptID: UUID
    ) -> TerminalConnectionStatusPresentationIdentity? {
        switch presentation {
        case .hidden, .connecting:
            return nil
        case .disconnected, .failed:
            return TerminalConnectionStatusPresentationIdentity(
                presentation: presentation,
                connectionAttemptID: connectionAttemptID
            )
        }
    }

    static func shouldPresent(
        identity: TerminalConnectionStatusPresentationIdentity?,
        dismissedIdentity: TerminalConnectionStatusPresentationIdentity?,
        isActive: Bool
    ) -> Bool {
        isActive && identity != nil && identity != dismissedIdentity
    }

    static func retainedDismissedIdentity(
        currentIdentity: TerminalConnectionStatusPresentationIdentity?,
        dismissedIdentity: TerminalConnectionStatusPresentationIdentity?
    ) -> TerminalConnectionStatusPresentationIdentity? {
        currentIdentity == dismissedIdentity ? dismissedIdentity : nil
    }
}

enum TerminalConnectionPresentationPolicy {
    static func usesReconnectBanner(
        connectionState: ConnectionState,
        hasEstablishedConnection: Bool,
        automaticReconnectAllowed: Bool,
        isReconnectPreparationInFlight: Bool
    ) -> Bool {
        if isReconnectPreparationInFlight {
            return true
        }

        if case .reconnecting = connectionState {
            return true
        }

        guard hasEstablishedConnection else { return false }

        if connectionState.isConnecting {
            return true
        }

        switch connectionState {
        case .disconnected, .failed:
            return automaticReconnectAllowed
        case .idle, .connecting, .reconnecting, .connected:
            return false
        }
    }
}

enum TerminalConnectionWatchdogPolicy {
    static func shouldMonitor(
        connectionState: ConnectionState,
        isReady: Bool,
        terminalExists: Bool,
        isAwaitingUserSelection: Bool
    ) -> Bool {
        guard !isAwaitingUserSelection else { return false }

        return connectionState.isConnecting
            || (connectionState.isConnected && !isReady && !terminalExists)
    }
}

enum TerminalConnectionStartPolicy {
    static func shouldStart(connectionState: ConnectionState) -> Bool {
        switch connectionState {
        case .connecting, .reconnecting, .connected:
            return true
        case .disconnected, .failed, .idle:
            return false
        }
    }
}

enum TerminalSceneActivityPolicy {
    static func isActive(
        environmentIsActive: Bool,
        windowSceneIsActive: Bool?
    ) -> Bool {
        windowSceneIsActive ?? environmentIsActive
    }
}

enum TmuxInstallPromptPolicy {
    static func shouldPresent(for status: TmuxStatus?) -> Bool {
        status == .missing
    }
}
