import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalConnectionStatusPresentationTests {
    @Test
    func establishedReconnectUsesBannerInsteadOfBlockingStatus() {
        let presentation = resolve(
            connectionState: .reconnecting(attempt: 2),
            hasEstablishedConnection: true,
            terminalExists: true,
            isReady: true
        )

        #expect(presentation == .hidden)
    }

    @Test
    func automaticReconnectNeverUsesActionSheet() {
        let presentation = resolve(
            connectionState: .reconnecting(attempt: 1),
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func automaticReconnectHidesTransientDisconnectedActionSheet() {
        let presentation = resolve(
            connectionState: .disconnected,
            hasEstablishedConnection: true,
            automaticReconnectAllowed: true,
            terminalExists: true,
            isReady: true
        )

        #expect(presentation == .hidden)
    }

    @Test
    func automaticReconnectHidesTransientFailedActionSheetBetweenRetryBatches() {
        let presentation = resolve(
            connectionState: .failed(terminalExternalFailure("Connection timed out")),
            hasEstablishedConnection: true,
            automaticReconnectAllowed: true,
            terminalExists: true,
            isReady: true
        )

        #expect(presentation == .hidden)
    }

    @Test
    func onlyTransientSSHFailuresAllowAutomaticRetry() {
        #expect(SSHError.timeout.allowsAutomaticReconnectRetry)
        #expect(SSHError.socketError("reset").allowsAutomaticReconnectRetry)
        #expect(SSHError.moshUDPTimeout.allowsAutomaticReconnectRetry)
        #expect(!SSHError.authenticationFailed.allowsAutomaticReconnectRetry)
        #expect(!SSHError.hostKeyVerificationFailed.allowsAutomaticReconnectRetry)
        #expect(!SSHError.hostKeyApprovalRequired.allowsAutomaticReconnectRetry)
        #expect(!SSHError.moshServerMissing.allowsAutomaticReconnectRetry)
    }

    @Test
    func failedEstablishedSessionKeepsRetryScheduledWhileForegroundConditionsChange() {
        #expect(TerminalAutoReconnectPolicy.shouldScheduleRetry(
            automaticReconnectAllowed: true,
            hasEstablishedConnection: true,
            connectionState: .failed(terminalExternalFailure("Temporary transport failure"))
        ))
        #expect(!TerminalAutoReconnectPolicy.shouldScheduleRetry(
            automaticReconnectAllowed: false,
            hasEstablishedConnection: true,
            connectionState: .failed(terminalExternalFailure("Authentication failed"))
        ))
    }

    @Test
    func intentionalTmuxDetachShowsDisconnectedStateInsteadOfReconnectBanner() {
        let presentation = resolve(
            connectionState: .disconnected,
            hasEstablishedConnection: true,
            automaticReconnectAllowed: false,
            terminalExists: true,
            isReady: true,
            disconnectedMessage: "tmux session is still running on the server."
        )

        #expect(
            presentation == .disconnected(
                message: "tmux session is still running on the server."
            )
        )
    }

    @Test
    func reconnectPreparationHidesPreviousFailureSheet() {
        let presentation = resolve(
            connectionState: .failed(terminalExternalFailure("Connection timed out")),
            hasEstablishedConnection: true,
            isReconnectPreparationInFlight: true,
            terminalExists: true,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func establishedConnectingStateUsesBannerEvenWhileTerminalReattaches() {
        let presentation = resolve(
            connectionState: .connecting,
            hasEstablishedConnection: true,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func restoredPaneKeepsReconnectPresentationAcrossViewRecreation() {
        var paneState = TerminalPaneState(
            paneId: UUID(),
            tabId: UUID(),
            serverId: UUID()
        )
        paneState.markConnectionEstablished()
        paneState.connectionState = .disconnected

        let presentation = resolve(
            connectionState: .connecting,
            hasEstablishedConnection: paneState.hasEstablishedConnection,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func firstReconnectAttemptUsesReconnectState() {
        #expect(
            TerminalConnectionAttemptPolicy.state(
                attempt: 1,
                hasEstablishedConnection: true
            ) == .reconnecting(attempt: 1)
        )
    }

    @Test
    func firstInitialAttemptUsesConnectingState() {
        #expect(
            TerminalConnectionAttemptPolicy.state(
                attempt: 1,
                hasEstablishedConnection: false
            ) == .connecting
        )
    }

    @Test
    func disconnectedStateCannotStartASecondConnectionDirectly() {
        #expect(!TerminalConnectionStartPolicy.shouldStart(connectionState: .disconnected))
        #expect(TerminalConnectionStartPolicy.shouldStart(connectionState: .reconnecting(attempt: 1)))
    }

    @Test
    func scenePhaseLagCannotReconnectAfterApplicationEnteredBackground() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: false,
            appIsLocked: false,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(!shouldReconnect)
    }

    @Test
    func foregroundReconnectStartsWhenApplicationIsActive() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            appIsLocked: false,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(shouldReconnect)
    }

    @Test
    func establishedSessionRetriesAfterReconnectBatchFails() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            appIsLocked: false,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .failed(terminalExternalFailure("Network path was not ready"))
        )

        #expect(shouldReconnect)
    }

    @Test
    func initialConnectionFailureDoesNotEnterAutomaticRetryLoop() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            appIsLocked: false,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: false,
            connectionState: .failed(terminalExternalFailure("Authentication failed"))
        )

        #expect(!shouldReconnect)
    }

    @Test
    func reconnectAlreadyInFlightRejectsOverlappingActivationTrigger() {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            appIsLocked: false,
            networkReadiness: .ready,
            automaticReconnectAllowed: true,
            reconnectInFlight: true,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(!shouldReconnect)
    }

    @Test(arguments: [TerminalNetworkReadiness.unknown, .unavailable])
    func automaticReconnectWaitsForReadyNetwork(readiness: TerminalNetworkReadiness) {
        let shouldReconnect = TerminalAutoReconnectPolicy.shouldAttempt(
            sceneIsActive: true,
            applicationIsActive: true,
            appIsLocked: false,
            networkReadiness: readiness,
            automaticReconnectAllowed: true,
            reconnectInFlight: false,
            hasEstablishedConnection: true,
            connectionState: .disconnected
        )

        #expect(!shouldReconnect)
    }

    @Test
    func tmuxInstallPromptRequiresConfirmedMissingStatus() {
        #expect(TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.missing))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.unknown))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.background))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.foreground))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.off))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: TmuxStatus.installing))
        #expect(!TmuxInstallPromptPolicy.shouldPresent(for: nil))
    }

    @Test
    func activeWindowSceneWinsWhileSwiftUIPhaseCatchesUp() {
        #expect(
            TerminalSceneActivityPolicy.isActive(
                environmentIsActive: false,
                windowSceneIsActive: true
            )
        )
    }

    @Test
    func backgroundWindowSceneWinsWhileSwiftUIPhaseCatchesUp() {
        #expect(!TerminalSceneActivityPolicy.isActive(
            environmentIsActive: true,
            windowSceneIsActive: false
        ))
    }

    @Test
    func windowSceneActivityFallsBackToSwiftUIBeforeTerminalAttaches() {
        #expect(
            TerminalSceneActivityPolicy.isActive(
                environmentIsActive: true,
                windowSceneIsActive: nil
            )
        )
    }

    @Test
    func initialConnectionUsesProgressPresentation() {
        let presentation = resolve(
            connectionState: .connecting,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .connecting(serverName: "Test Server"))
    }

    @Test
    func tmuxSelectionHidesInitialConnectionStatus() {
        let presentation = resolve(
            connectionState: .connecting,
            isAwaitingTmuxSelection: true,
            terminalExists: false,
            isReady: false
        )

        #expect(presentation == .hidden)
    }

    @Test
    func tmuxSelectionSuspendsConnectionWatchdog() {
        let shouldMonitor = TerminalConnectionWatchdogPolicy.shouldMonitor(
            connectionState: .connecting,
            isReady: false,
            terminalExists: false,
            isAwaitingUserSelection: true
        )

        #expect(!shouldMonitor)
    }

    @Test
    func connectionWatchdogResumesAfterTmuxSelection() {
        let shouldMonitor = TerminalConnectionWatchdogPolicy.shouldMonitor(
            connectionState: .connecting,
            isReady: false,
            terminalExists: false,
            isAwaitingUserSelection: false
        )

        #expect(shouldMonitor)
    }

    @Test
    func manualDisconnectedStateCarriesRecoveryContextIntoActionPresentation() {
        let message = "tmux session is still running on the server."
        let presentation = resolve(
            connectionState: .disconnected,
            disconnectedMessage: message
        )

        #expect(presentation == .disconnected(message: message))
    }

    @Test
    func tmuxDisconnectMessagesReflectLifecycleReason() {
        #expect(
            TerminalDisconnectReason.externalTmuxEnded.statusMessage
                == String(localized: "The tmux session has ended.")
        )
        #expect(
            TerminalDisconnectReason.tmuxDetached.statusMessage
                == String(localized: "tmux session is still running on the server.")
        )
        #expect(TerminalDisconnectReason.transportEnded.statusMessage == nil)
    }

    @Test
    func hostKeyFailureEnablesReplacementAction() {
        let presentation = resolve(
            connectionState: .failed(terminalExternalFailure(
                "Host key verification failed",
                retryDisposition: .manual,
                requiredAction: .approveHostKey
            ))
        )

        #expect(
            presentation == .failed(
                message: "Host key verification failed",
                allowsHostKeyReplacement: true
            )
        )
    }

    @Test
    func credentialFailureTakesPrecedenceOverConnectionState() {
        let presentation = resolve(
            credentialLoadErrorMessage: "Failed to load credentials",
            connectionState: .connected,
            terminalExists: true,
            isReady: true
        )

        #expect(
            presentation == .failed(
                message: "Failed to load credentials",
                allowsHostKeyReplacement: false
            )
        )
    }

    @Test
    func dismissedStatusIdentityDoesNotImmediatelyPresentAgain() throws {
        let attemptID = UUID()
        let identity = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(message: "Connection timed out", allowsHostKeyReplacement: false),
            connectionAttemptID: attemptID
        ))

        #expect(!TerminalConnectionStatusDismissalPolicy.shouldPresent(
            identity: identity,
            dismissedIdentity: identity,
            isActive: true
        ))
    }

    @Test
    func dismissingStatusDoesNotChangeItsConnectionPresentation() throws {
        let presentation = TerminalConnectionStatusPresentation.disconnected(
            message: "The remote session ended."
        )
        let identity = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: presentation,
            connectionAttemptID: UUID()
        ))

        #expect(identity.presentation == presentation)
    }

    @Test
    func changedStatusPresentsAfterPreviousIdentityWasDismissed() throws {
        let attemptID = UUID()
        let dismissed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(message: "Timed out", allowsHostKeyReplacement: false),
            connectionAttemptID: attemptID
        ))
        let changed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .disconnected(message: "The remote session ended."),
            connectionAttemptID: attemptID
        ))

        #expect(TerminalConnectionStatusDismissalPolicy.shouldPresent(
            identity: changed,
            dismissedIdentity: dismissed,
            isActive: true
        ))
    }

    @Test
    func newAttemptPresentsEvenWhenFailureTextIsUnchanged() throws {
        let presentation = TerminalConnectionStatusPresentation.failed(
            message: "Connection timed out",
            allowsHostKeyReplacement: false
        )
        let dismissed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: presentation,
            connectionAttemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ))
        let nextAttempt = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: presentation,
            connectionAttemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ))

        #expect(TerminalConnectionStatusDismissalPolicy.shouldPresent(
            identity: nextAttempt,
            dismissedIdentity: dismissed,
            isActive: true
        ))
    }

    @Test
    func hiddenOrChangedStatusClearsTheRetainedDismissal() throws {
        let dismissed = try #require(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(message: "Connection timed out", allowsHostKeyReplacement: false),
            connectionAttemptID: UUID()
        ))

        #expect(TerminalConnectionStatusDismissalPolicy.retainedDismissedIdentity(
            currentIdentity: nil,
            dismissedIdentity: dismissed
        ) == nil)
    }

    @Test
    func onlyRecoveryStatusesCreateSheetIdentities() {
        let attemptID = UUID()

        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .hidden,
            connectionAttemptID: attemptID
        ) == nil)
        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .connecting(serverName: "Production"),
            connectionAttemptID: attemptID
        ) == nil)
        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .disconnected(message: nil),
            connectionAttemptID: attemptID
        ) != nil)
        #expect(TerminalConnectionStatusDismissalPolicy.identity(
            for: .failed(
                message: "Authentication failed",
                allowsHostKeyReplacement: false
            ),
            connectionAttemptID: attemptID
        ) != nil)
    }

    private func resolve(
        credentialLoadErrorMessage: String? = nil,
        connectionState: ConnectionState,
        hasEstablishedConnection: Bool = false,
        automaticReconnectAllowed: Bool = false,
        isReconnectPreparationInFlight: Bool = false,
        isAwaitingTmuxSelection: Bool = false,
        terminalExists: Bool = true,
        isReady: Bool = true,
        disconnectedMessage: String? = nil
    ) -> TerminalConnectionStatusPresentation {
        .resolve(
            credentialLoadErrorMessage: credentialLoadErrorMessage,
            connectionState: connectionState,
            serverName: "Test Server",
            hasEstablishedConnection: hasEstablishedConnection,
            automaticReconnectAllowed: automaticReconnectAllowed,
            isReconnectPreparationInFlight: isReconnectPreparationInFlight,
            isAwaitingTmuxSelection: isAwaitingTmuxSelection,
            terminalExists: terminalExists,
            isReady: isReady,
            disconnectedMessage: disconnectedMessage
        )
    }
}
