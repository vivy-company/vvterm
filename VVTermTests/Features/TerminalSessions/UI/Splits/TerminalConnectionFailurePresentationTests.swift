import Foundation
import Testing
@testable import VVTerm

nonisolated func terminalExternalFailure(
    _ message: String,
    retryDisposition: TerminalConnectionRetryDisposition = .automatic,
    requiredAction: TerminalConnectionRequiredAction? = nil
) -> TerminalConnectionFailure {
    .external(
        message: message,
        retryDisposition: retryDisposition,
        requiredAction: requiredAction
    )
}

struct TerminalConnectionFailurePresentationTests {
    @Test
    func mapsCoordinatorFailuresToExactLocalizedCopy() {
        #expect(
            TerminalConnectionFailurePresentation.message(for: .reconnectTimedOut)
                == String(localized: "Connection timed out. Please retry.")
        )
        #expect(
            TerminalConnectionFailurePresentation.message(for: .tmuxStartupFailed)
                == String(localized: "Unable to start tmux session.")
        )
        #expect(
            TerminalTabOpeningError.alreadyOpening.localizedDescription
                == String(
                    format: String(localized: "Connection failed: %@"),
                    String(localized: "A tab is already opening for this server.")
                )
        )
    }

    @Test
    func mapsEveryFixedEternalTerminalFailureToExactLocalizedCopy() {
        let mappings: [(EternalTerminalSessionFailure, String)] = [
            (
                .bootstrapSSH,
                String(localized: "Eternal Terminal could not start through SSH. Verify the SSH credentials and that etterminal is installed on the host.")
            ),
            (
                .malformedBootstrapCredentials,
                String(localized: "etterminal returned malformed connection details. Update Eternal Terminal on the host and try again.")
            ),
            (
                .invalidKey,
                String(localized: "etserver rejected the session key. Reconnect to start a new Eternal Terminal session.")
            ),
            (
                .protocolMismatch,
                String(localized: "The Eternal Terminal client and server protocol versions do not match. Update Eternal Terminal on the host.")
            ),
            (
                .disconnectedBufferFull,
                String(localized: "Eternal Terminal could not buffer more input while offline. Reconnect and try again.")
            ),
            (
                .connectionInProgress,
                String(localized: "An Eternal Terminal connection is already starting.")
            ),
            (
                .connectionClosed,
                String(localized: "The Eternal Terminal session closed. Reconnect to start a new session.")
            ),
            (
                .applicationSuspended,
                String(localized: "Eternal Terminal input is paused while VVTerm is in the background.")
            ),
            (
                .sessionUnrecoverable,
                String(localized: "The Eternal Terminal session can no longer recover. Reconnect to start a new session.")
            ),
            (
                .client,
                String(localized: "Eternal Terminal could not establish the session. Verify the server installation and try again.")
            ),
            (
                .unknown,
                String(localized: "Eternal Terminal could not connect. Verify etserver is running and the configured ET port is reachable.")
            )
        ]

        for (failure, expected) in mappings {
            #expect(eternalTerminalMessage(for: failure) == expected)
        }
        #expect(
            eternalTerminalMessage(for: .transport)
                == String(
                    format: String(localized: "Could not reach etserver at %@:%d. Verify etserver is running and TCP port %d is open."),
                    "et.example.com",
                    22022,
                    22022
                )
        )
        #expect(
            eternalTerminalMessage(for: .resumeState(
                message: "Resume credentials expired",
                discardStoredState: true
            )) == "Resume credentials expired"
        )
    }

    @Test
    func mapsEveryBootstrapResponseBranchToExactCopy() {
        #expect(
            eternalTerminalMessage(for: .bootstrapResponse(""))
                == String(localized: "etterminal did not return valid connection details. Verify the Eternal Terminal installation on the host.")
        )
        #expect(
            eternalTerminalMessage(for: .bootstrapResponse("bad response"))
                == String(
                    format: String(localized: "etterminal did not return valid connection details. Host response: %@"),
                    "bad response"
                )
        )
        #expect(
            eternalTerminalMessage(for: .bootstrapResponse(
                "VVTERM_ET_UNSUPPORTED_NATIVE_WINDOWS"
            )) == String(localized: "Eternal Terminal does not run as a native Windows PowerShell or Command Prompt service. Configure this SSH connection to open inside WSL with Eternal Terminal installed, or use SSH with psmux instead.")
        )
        #expect(
            eternalTerminalMessage(for: .bootstrapResponse(
                "VVTERM_ET_REQUIRES_POSIX_SHELL"
            )) == String(localized: "Eternal Terminal requires a POSIX login shell with /bin/sh. Configure this SSH connection to open a supported Linux, macOS, BSD, or WSL environment, then try again.")
        )
        #expect(
            eternalTerminalMessage(for: .bootstrapResponse(
                "Error communicating with et daemon"
            )) == String(localized: "Eternal Terminal is installed, but its server daemon is not running or uses a different socket. On Linux, run “sudo systemctl enable --now et”. On macOS with Homebrew, run “brew services start et”. Then try again. If it still fails, ensure etterminal and etserver use the same server FIFO.")
        )
    }

    @Test
    func preservesExternalTransportCopyAndExactANSIEnvelope() throws {
        let failure = terminalExternalFailure(
            "Authentication failed",
            retryDisposition: .manual
        )

        #expect(
            TerminalConnectionFailurePresentation.message(for: failure)
                == "Authentication failed"
        )
        let output = try #require(
            TerminalConnectionFailurePresentation.ansiSSHErrorData(for: failure)
        )
        #expect(
            String(decoding: output, as: UTF8.self)
                == "\r\n\u{001B}[31mSSH Error: Authentication failed\u{001B}[0m\r\n"
        )
    }

    @Test
    func transportMappingPreservesRecoveryAndRequiredActionFacts() {
        let timeout = TerminalConnectionFailure.transport(SSHError.timeout)
        let approval = TerminalConnectionFailure.transport(
            SSHError.hostKeyApprovalRequired
        )

        #expect(timeout.allowsAutomaticReconnectRetry)
        #expect(timeout.requiredAction == nil)
        #expect(!approval.allowsAutomaticReconnectRetry)
        #expect(approval.requiredAction == .approveHostKey)
        #expect(
            TerminalConnectionFailurePresentation.message(for: approval)
                == SSHError.hostKeyApprovalRequired.localizedDescription
        )

        struct WrappedApprovalError: LocalizedError {
            var errorDescription: String? {
                "Wrapped transport: host key approval is required"
            }
        }
        #expect(
            TerminalConnectionFailure.transport(WrappedApprovalError()).requiredAction
                == .approveHostKey
        )
    }

    private func eternalTerminalMessage(
        for failure: EternalTerminalSessionFailure
    ) -> String {
        TerminalConnectionFailurePresentation.message(
            for: .eternalTerminal(
                failure: failure,
                host: "et.example.com",
                port: 22022
            )
        )
    }
}
