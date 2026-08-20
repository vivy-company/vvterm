import Foundation
import Testing
@testable import VVTerm

struct RemoteTmuxOwnershipTests {
    @Test @MainActor
    func selectedVVTermManagedSessionKeepsManagedClearBehavior() throws {
        let coordinator = TerminalTmuxSessionCoordinator()
        let paneId = UUID()
        let sessionName = coordinator.managedSessionName(for: paneId)
        let selection = TmuxAttachSelection.attachExisting(sessionName: sessionName)

        coordinator.updateAttachmentState(for: paneId, selection: selection)
        let ownership = try #require(coordinator.attachment(for: paneId)?.ownership)
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: sessionName,
            ownership: ownership
        )

        #expect(ownership == .managed)
        #expect(command.contains("set-option -wq -t \"$vvtermWindow\" scroll-on-clear 'off'"))
        #expect(command.contains("set-hook -t '=\(sessionName):' 'after-new-window[1000]'"))
    }

    @Test @MainActor
    func selectedExternalSessionDoesNotLoadVVTermConfiguration() throws {
        let coordinator = TerminalTmuxSessionCoordinator()
        let paneId = UUID()
        let selection = TmuxAttachSelection.attachExisting(sessionName: "shared")

        coordinator.updateAttachmentState(for: paneId, selection: selection)
        let ownership = try #require(coordinator.attachment(for: paneId)?.ownership)
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteTmuxThemeStyle,
            sessionName: "shared",
            ownership: ownership
        )

        #expect(ownership == .external)
        #expect(!command.contains("source-file"))
        #expect(!command.contains("~/.vvterm/tmux.conf"))
    }

    @Test @MainActor
    func failedExternalSessionListingPreservesRememberedAttachment() async {
        let coordinator = TerminalTmuxSessionCoordinator()
        let paneId = UUID()
        let serverId = UUID()
        coordinator.setAttachment(
            for: paneId,
            sessionName: "shared-session",
            ownership: .external
        )

        do {
            _ = try await coordinator.resolveSelection(
                for: paneId,
                serverId: serverId,
                client: SSHClient.testing(),
                backend: .unixTmux,
                requestId: UUID(),
                validateOwner: {}
            )
            Issue.record("A failed session listing should remain a retryable connection error")
        } catch {
            #expect(error is SSHError)
        }

        #expect(coordinator.attachment(for: paneId)?.sessionName == "shared-session")
        #expect(coordinator.attachment(for: paneId)?.ownership == .external)
    }
}

