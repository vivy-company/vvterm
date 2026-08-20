import Foundation
import Testing
@testable import VVTerm

struct ServerApplicationErrorPresentationTests {
    @Test
    func hostKeyApprovalExpirationKeepsItsExactDescription() {
        let failure = ServerConnectionTestFailure(
            reason: .hostKeyApprovalExpired,
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )
        let expected = String(localized: "SSH host key approval expired. Try again.")

        #expect(failure.message == expected)
    }

    @Test
    func connectionFailureMessagePassesThrough() {
        let failure = ServerConnectionTestFailure(
            reason: .message("Connection refused"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )

        #expect(failure.message == "Connection refused")
    }

    @Test
    func tailscaleReminderIsAppendedExactlyOnce() {
        let reminder = String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback).")
        let withoutReminder = ServerConnectionTestFailure(
            reason: .tailscale("Authentication failed"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )
        let withReminder = ServerConnectionTestFailure(
            reason: .tailscale("Authentication failed\n\(reminder)"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )

        #expect(withoutReminder.message == "Authentication failed\n\(reminder)")
        #expect(withReminder.message == "Authentication failed\n\(reminder)")
    }

    @Test
    func eternalTerminalFailureUsesTheTerminalPresentationCatalog() {
        let failure = ServerConnectionTestFailure(
            reason: .eternalTerminal(
                failure: .transport,
                host: "et.example.com",
                port: 22022
            ),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )

        let expected = String(
            format: String(localized: "Could not reach etserver at %@:%d. Verify etserver is running and TCP port %d is open."),
            "et.example.com",
            22022,
            22022
        )
        #expect(failure.message == expected)
    }

    @Test
    func mapsEveryVVTermErrorToItsExactDescription() {
        let mappings: [(VVTermError, String)] = [
            (
                .proRequired(.unlimitedServers),
                String(localized: "Upgrade to Pro for unlimited servers")
            ),
            (
                .proRequired(.unlimitedWorkspaces),
                String(localized: "Upgrade to Pro for unlimited workspaces")
            ),
            (
                .proRequired(.moveIntoLockedWorkspace),
                String(localized: "Upgrade to Pro to move servers into locked workspaces")
            ),
            (
                .serverLocked("Production"),
                String(format: String(localized: "Server '%@' is locked"), "Production")
            ),
            (
                .workspaceLocked("Work"),
                String(format: String(localized: "Workspace '%@' is locked"), "Work")
            ),
            (
                .moveNotAllowed(.destinationUnavailable),
                String(localized: "The destination workspace is no longer available.")
            ),
            (
                .moveNotAllowed(.unavailable),
                String(localized: "This server can't be moved to that workspace right now.")
            ),
            (
                .connectionFailed("Host unreachable"),
                String(format: String(localized: "Connection failed: %@"), "Host unreachable")
            ),
            (.authenticationFailed, String(localized: "Authentication failed")),
            (.authorizationRequired, String(localized: "Authorization is required")),
            (.serverNotFound, String(localized: "Server no longer exists.")),
            (.workspaceNotFound, String(localized: "Workspace no longer exists.")),
            (
                .workspaceDeletionChanged,
                String(localized: "The workspace changed while deletion was authorized. Review it and try again.")
            ),
            (
                .serverDataMutationRecoveryPending,
                String(localized: "The server data change is still being recovered. Try again after recovery completes.")
            ),
            (.timeout, String(localized: "Connection timed out"))
        ]

        for (error, expected) in mappings {
            #expect(error.errorDescription == expected)
            #expect(error.localizedDescription == expected)
        }
    }

}
