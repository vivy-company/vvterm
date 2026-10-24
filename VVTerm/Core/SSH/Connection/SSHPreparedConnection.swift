import Foundation

nonisolated struct SSHPreparedConnectionRequest: Equatable, Sendable {
    let profileID: String
    let clusterName: String
    let nodeID: String
    let login: String
}

typealias SSHPreparedConnectionProvider = @Sendable (
    SSHPreparedConnectionRequest
) async throws -> any SSHPreparedConnection

/// A provider-owned byte stream with certificate credentials and host trust.
/// The session retains this owner until native SSH work has stopped and its
/// transferred descriptor has been closed.
nonisolated protocol SSHPreparedConnection: AnyObject, Sendable {
    var sshCertificate: Data { get }
    var sshPrivateKey: Data { get }

    /// Transfers one connected, nonblocking stream descriptor to the SSH session.
    func takeSocketDescriptor() throws -> Int32

    /// Verifies the complete host certificate, never a fingerprint or raw key.
    func verifyHostCertificate(_ certificate: Data) throws

    /// Releases the provider stream after the SSH session has stopped.
    func close() async
}
