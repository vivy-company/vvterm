import Foundation

nonisolated struct ShellHandle: Sendable {
    let id: UUID
    let stream: TerminalOutputStream
    let transportState: ShellTransportState
    let origin: ShellStartOrigin

    var transport: ShellTransport { transportState.transport }
    var fallbackReason: MoshFallbackReason? { transportState.fallbackReason }
    var fallbackDiagnostics: MoshFallbackDiagnostics? { transportState.fallbackDiagnostics }

    init(
        id: UUID,
        stream: TerminalOutputStream,
        transportState: ShellTransportState = .ssh,
        origin: ShellStartOrigin = .fresh
    ) {
        self.id = id
        self.stream = stream
        self.transportState = transportState
        self.origin = origin
    }
}

nonisolated enum ShellStartOrigin: Equatable, Sendable {
    case fresh
    case restored
}
