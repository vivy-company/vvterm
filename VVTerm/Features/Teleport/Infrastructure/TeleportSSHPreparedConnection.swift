import Foundation
import TeleportKit

nonisolated final class TeleportSSHPreparedConnection: SSHPreparedConnection {
    private let connection: TeleportConnection

    init(connection: TeleportConnection) { self.connection = connection }

    var sshCertificate: Data { Data(connection.sshCertificateOpenSSH.utf8) }
    var sshPrivateKey: Data { Data(connection.sshPrivateKeyPEM.utf8) }
    func takeSocketDescriptor() throws -> Int32 { try connection.takeSocketDescriptor() }
    func verifyHostCertificate(_ certificate: Data) throws {
        try connection.verifyHostCertificate(certificate)
    }
    func close() async { await connection.close() }
}
