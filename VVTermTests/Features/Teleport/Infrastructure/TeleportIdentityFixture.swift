#if os(macOS)
import Foundation
import Security
import TeleportKit

/// Fresh test credentials stay in a private temporary directory and are removed.
nonisolated final class TeleportIdentityFixture: Sendable {
    let identity: TeleportIdentity
    private let directory: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-teleport-test-" + UUID().uuidString)
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        do { identity = try Self.makeIdentity(in: directory) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private static func makeIdentity(in directory: URL) throws -> TeleportIdentity {
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        func write(_ data: Data, _ name: String) throws {
            try data.write(to: directory.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path(name))
        }
        let configurationURL = directory.appendingPathComponent("ca.conf")
        func run(_ executable: String, _ arguments: [String]) throws -> Data {
            try Self.run(executable, arguments, configurationURL: configurationURL)
        }
        let config = "[req]\ndistinguished_name=dn\n[dn]\n[v3_ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
        try write(Data(config.utf8), "ca.conf")
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 3072]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let privateDER = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw FixtureError.key
        }
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n"
            + privateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END RSA PRIVATE KEY-----\n"
        try write(Data(pem.utf8), "client.key")
        try write(try run("/usr/bin/ssh-keygen", ["-y", "-f", path("client.key")]), "client.pub")
        for name in ["user-ca", "host-ca"] {
            _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path(name)])
        }
        _ = try run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path("tls-ca.key"),
            "-out", path("tls-ca.pem"), "-subj", "/CN=root/O=root", "-days", "1",
            "-config", path("ca.conf"), "-extensions", "v3_ca",
        ])
        _ = try run("/usr/bin/ssh-keygen", [
            "-q", "-s", path("user-ca"), "-I", "alice", "-n", "alice", "-V", "-1m:+1h", path("client.pub"),
        ])
        _ = try run("/usr/bin/openssl", [
            "req", "-new", "-key", path("client.key"), "-out", path("client.csr"), "-subj", "/CN=alice",
            "-config", path("ca.conf"),
        ])
        // There is one leaf per fresh CA. An explicit serial also avoids
        // LibreSSL deriving a file path from the container's dotted name.
        _ = try run("/usr/bin/openssl", [
            "x509", "-req", "-in", path("client.csr"), "-CA", path("tls-ca.pem"),
            "-CAkey", path("tls-ca.key"), "-set_serial", "1", "-days", "1", "-out", path("client.pem"),
        ])
        let authority = try certificate(at: directory.appendingPathComponent("tls-ca.pem"))
        return try TeleportIdentity(
            proxy: TeleportProxy(url: URL(string: "https://proxy.example.test")!), username: "alice", clusterName: "root",
            tlsCertificateDER: certificate(at: directory.appendingPathComponent("client.pem")),
            tlsPrivateKeyDER: privateDER,
            sshCertificateOpenSSH: String(contentsOfFile: path("client-cert.pub"), encoding: .utf8),
            tlsCACertificatesDER: [authority], sshHostCAKeys: [String(contentsOfFile: path("host-ca.pub"), encoding: .utf8)],
            tlsUserCACertificatesDER: [authority], sshUserCAKeys: [String(contentsOfFile: path("user-ca.pub"), encoding: .utf8)]
        )
    }

    private enum FixtureError: Error {
        case key
        case certificate
        case command(tool: String, verb: String, status: Int32)
    }

    private static func certificate(at url: URL) throws -> Data {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard let data = Data(base64Encoded: lines.filter { !$0.hasPrefix("-----") }.joined()) else {
            throw FixtureError.certificate
        }
        return data
    }

    private static func run(_ executable: String, _ arguments: [String], configurationURL: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // LibreSSL reads this before command options. The app sandbox cannot
        // rely on the system's default config, even when req has -config.
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSSL_CONF"] = configurationURL.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.command(
                tool: URL(fileURLWithPath: executable).lastPathComponent,
                verb: arguments.first ?? "",
                status: process.terminationStatus
            )
        }
        return data
    }
}
#endif
