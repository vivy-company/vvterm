import CoreGraphics
import Foundation

/// Selects one application transport coordinator per pane. Transport state is
/// retained by the app-scoped transport owner so view reconstruction cannot
/// replace a live session.
@MainActor
final class TerminalPaneConnectionCoordinator {
    private enum Backend {
        case ssh(TerminalPaneSSHCoordinator)
        case eternalTerminal(EternalTerminalPaneCoordinator)
    }

    let tabManager: TerminalTabManager
    weak var terminal: (any TerminalSurface)?
    var isTerminalReady = false
    var preservePane = false
    var lastReportedSize: CGSize = .zero
    private let backend: Backend

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        tabManager: TerminalTabManager,
        sshFailureOutput: @escaping @MainActor @Sendable (TerminalConnectionFailure) -> Data?
    ) {
        self.tabManager = tabManager
        if server.connectionMode == .eternalTerminal {
            backend = .eternalTerminal(EternalTerminalPaneCoordinator(
                paneId: paneId,
                server: server,
                credentials: credentials,
                tabManager: tabManager
            ))
        } else {
            backend = .ssh(TerminalPaneSSHCoordinator(
                paneId: paneId,
                server: server,
                credentials: credentials,
                sshClient: tabManager.transportCoordinator.makeSSHClient(),
                tabManager: tabManager,
                failureOutput: sshFailureOutput
            ))
        }
    }

    var paneId: UUID {
        switch backend {
        case .ssh(let coordinator): coordinator.paneId
        case .eternalTerminal(let coordinator): coordinator.paneId
        }
    }

    var hasLiveConnection: Bool {
        tabManager.transportCoordinator.hasLiveTransport(for: paneId)
    }

    var isConnectionStartInFlight: Bool {
        tabManager.transportCoordinator.isTransportStartInFlight(for: paneId)
    }

    func installRichPasteInterception(on terminal: any TerminalSurface) {
        guard case .ssh(let coordinator) = backend else { return }
        coordinator.installRichPasteInterception(on: terminal)
    }

    func sendToTransport(_ data: Data) {
        switch backend {
        case .ssh(let coordinator): coordinator.sendToSSH(data)
        case .eternalTerminal(let coordinator): coordinator.send(data)
        }
    }

    func handleResize(cols: Int, rows: Int) {
        let pixelSize = terminal?.terminalGeometry?.pixelSize
        switch backend {
        case .ssh(let coordinator):
            coordinator.handleResize(cols: cols, rows: rows, pixelSize: pixelSize)
        case .eternalTerminal(let coordinator):
            coordinator.handleResize(cols: cols, rows: rows, pixelSize: pixelSize)
        }
    }

    func startConnection(terminal: any TerminalSurface) {
        self.terminal = terminal
        switch backend {
        case .ssh(let coordinator): coordinator.startSSHConnection(terminal: terminal)
        case .eternalTerminal(let coordinator): coordinator.start(terminal: terminal)
        }
    }

    func cancelConnection() {
        terminal = nil
        switch backend {
        case .ssh:
            break
        case .eternalTerminal(let coordinator): coordinator.cancel()
        }
    }
}

@MainActor
private final class EternalTerminalPaneCoordinator {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let tabManager: TerminalTabManager

    init(
        paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        tabManager: TerminalTabManager
    ) {
        self.paneId = paneId
        self.server = server
        self.credentials = credentials
        self.tabManager = tabManager
    }

    func start(terminal: any TerminalSurface) {
        let runtime = tabManager.transportCoordinator.eternalTerminalRuntime(
            for: paneId,
            server: server,
            credentials: credentials
        )
        runtime.attach(to: terminal)
        guard let geometry = terminal.terminalGeometry else { return }
        runtime.resize(
            cols: geometry.columns,
            rows: geometry.rows,
            pixelSize: geometry.pixelSize
        )
        runtime.startIfNeeded()
    }

    func send(_ data: Data) {
        tabManager.transportCoordinator.sendEternalTerminalInput(data, for: paneId)
    }

    func handleResize(cols: Int, rows: Int, pixelSize: TerminalPixelSize?) {
        tabManager.transportCoordinator.resizeEternalTerminal(
            for: paneId,
            cols: cols,
            rows: rows,
            pixelSize: pixelSize
        )
    }

    func cancel() {
        tabManager.transportCoordinator.unregisterEternalTerminalRuntimeIfPaneWasRemoved(
            for: paneId
        )
    }
}
