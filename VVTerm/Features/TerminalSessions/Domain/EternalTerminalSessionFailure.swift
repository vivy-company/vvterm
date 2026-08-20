import Foundation

nonisolated enum EternalTerminalSessionFailure: Error, Hashable, Sendable {
    case bootstrapSSH
    case bootstrapResponse(String)
    case malformedBootstrapCredentials
    case resumeState(message: String, discardStoredState: Bool)
    case transport
    case invalidKey
    case protocolMismatch
    case disconnectedBufferFull
    case connectionInProgress
    case connectionClosed
    case applicationSuspended
    case sessionUnrecoverable
    case client
    case unknown
}
