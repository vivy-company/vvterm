#if os(macOS)
import Foundation
import SwiftUI
import AppKit

extension View {
    func terminalCommandFocusValues(
        activeServerId: UUID?,
        activePaneId: UUID?,
        splitActions: TerminalSplitActions?
    ) -> some View {
        self
            .focusedValue(\.activeServerId, activeServerId)
            .focusedValue(\.activePaneId, activePaneId)
            .focusedSceneValue(\.terminalSplitActions, splitActions)
    }

    func terminalKeyboardAvoidance(
        focusedPaneId: UUID?,
        paneIds: [UUID],
        terminalSurfaceChange: TerminalSurfaceStoreChange?,
        terminalProvider: @escaping (UUID) -> GhosttyTerminalView?
    ) -> some View {
        self
    }
}

// MARK: - SSH Terminal Pane Wrapper

/// Wraps a remote connection and Ghostty terminal for a pane.
struct RemoteTerminalPaneWrapper: NSViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let tabManager: TerminalTabManager
    let isActive: Bool
    let terminalContextMenuActions: TerminalContextMenuActions
    let onProcessExit: () -> Void
    let onReady: () -> Void

    @EnvironmentObject var ghosttyApp: GhosttyRuntime

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator

        // Check if terminal already exists for this pane (reuse to save memory)
        if let existingTerminal = tabManager.terminalSurfaceStore.ghosttySurface(for: paneId) {
            coordinator.preservePane = true
            coordinator.terminal = existingTerminal
            existingTerminal.onProcessExit = processExitHandler(for: existingTerminal)

            // Update resize callback to use tab manager's registered SSH client
            existingTerminal.onResize = { [weak coordinator] cols, rows in
                coordinator?.handleResize(cols: cols, rows: rows)
            }
            existingTerminal.onPwdChange = { [paneId] rawDirectory in
                tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
            existingTerminal.onTitleChange = { [paneId] title in
                tabManager.updatePaneTitle(paneId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [paneId] action in
                tabManager.handleTerminalZoom(action, for: paneId)
            }
            existingTerminal.terminalContextMenuActions = terminalContextMenuActions
            existingTerminal.applyPresentationOverrides(
                tabManager.sessionState.presentationOverrides(for: paneId)
            )
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToTransport(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            DispatchQueue.main.async {
                onReady()
                if tabManager.transportCoordinator.activeSSHRoute(for: paneId) == nil {
                    coordinator.startConnection(terminal: existingTerminal)
                }
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            if let terminalView = terminalView {
                coordinator?.startConnection(terminal: terminalView)
            }
        }
        terminalView.onProcessExit = processExitHandler(for: terminalView)
        terminalView.onPwdChange = { [paneId] rawDirectory in
            tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
        }
        terminalView.onTitleChange = { [paneId] title in
            tabManager.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [paneId] action in
            tabManager.handleTerminalZoom(action, for: paneId)
        }
        terminalView.terminalContextMenuActions = terminalContextMenuActions
        terminalView.applyPresentationOverrides(
            tabManager.sessionState.presentationOverrides(for: paneId)
        )

        // Store terminal reference
        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        tabManager.registerTerminalSurface(terminalView, for: paneId)

        // Route terminal input to the selected remote transport.
        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToTransport(data)
        }
        terminalView.setupWriteCallback()

        // Setup resize callback to notify SSH of terminal size changes
        terminalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.handleResize(cols: cols, rows: rows)
        }

        // Wrap in scroll view
        let scrollView = TerminalScrollView(
            contentSize: NSSize(width: 800, height: 600),
            surfaceView: terminalView
        )

        return scrollView
    }

    private func processExitHandler(for terminal: GhosttyTerminalView) -> () -> Void {
        { [weak terminal] in
            guard let terminal,
                  tabManager.terminalSurfaceStore.isRegistered(
                    terminal,
                    for: paneId
                  ) else { return }
            onProcessExit()
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let scrollView = nsView as? TerminalScrollView {
            scrollView.shouldOwnFirstResponder = isActive
            let terminalView = scrollView.surfaceView
            terminalView.terminalContextMenuActions = terminalContextMenuActions
            let presentationOverrides = tabManager.sessionState.presentationOverrides(for: paneId)
            if terminalView.surfacePresentationOverrides != presentationOverrides {
                terminalView.applyPresentationOverrides(presentationOverrides)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: TerminalPaneConnectionCoordinator) {
        guard let scrollView = nsView as? TerminalScrollView else { return }
        let terminal = scrollView.surfaceView
        let paneStillExists = coordinator.tabManager.sessionState
            .paneState(for: coordinator.paneId) != nil
        if paneStillExists {
            coordinator.preservePane = true
            return
        }

        coordinator.terminal = nil
        let paneId = coordinator.paneId
        DispatchQueue.main.async {
            coordinator.tabManager.unregisterTerminalSurface(terminal, for: paneId)
            coordinator.cancelConnection()
        }
    }

    func makeCoordinator() -> TerminalPaneConnectionCoordinator {
        TerminalPaneConnectionCoordinator(
            paneId: paneId,
            server: server,
            credentials: credentials,
            tabManager: tabManager,
            sshFailureOutput: { failure in
                TerminalConnectionFailurePresentation.ansiSSHErrorData(for: failure)
            }
        )
    }
}
#endif
