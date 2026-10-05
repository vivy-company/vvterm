import Foundation

nonisolated enum ZmxRemoteSessionParser {
    static let maximumOutputBytes = 32 * 1_024
    static let maximumSessionCount = 256
    static let maximumAttachedClientCount = 4_096

    struct ProbeResult: Equatable, Sendable {
        let executable: RemoteSessionExecutable
        let rawVersion: String
        let semanticVersion: RemoteSessionSemanticVersion
    }

    static func parseProbe(_ output: String) -> ProbeResult? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.contains(ZmxRemoteSessionCommandBuilder.availableMarker),
              let pathLine = lines.first(where: {
                  $0.hasPrefix(ZmxRemoteSessionCommandBuilder.pathMarker)
              }) else {
            return nil
        }
        let rawPath = String(pathLine.dropFirst(ZmxRemoteSessionCommandBuilder.pathMarker.count))
        guard let executable = try? RemoteSessionExecutable(validating: rawPath),
              let versionLine = lines.first(where: { line in
                  line.split(whereSeparator: \.isWhitespace).first == "zmx"
              }),
              let semanticVersion = RemoteSessionSemanticVersion(versionLine) else {
            return nil
        }
        return ProbeResult(
            executable: executable,
            rawVersion: versionLine,
            semanticVersion: semanticVersion
        )
    }

    static func parseSessionList(
        _ output: String,
        scope: RemoteSessionListScope = .userVisible
    ) throws -> [RemoteSessionDescriptor] {
        guard output.utf8.count <= maximumOutputBytes else {
            throw SSHError.outputLimitExceeded
        }
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count <= maximumSessionCount else {
            throw SSHError.outputLimitExceeded
        }
        var seen: Set<RemoteSessionIdentifier> = []
        let sessions = try lines.map { rawLine in
            let parsed = try parseSessionLine(rawLine)
            let identifier = try RemoteSessionIdentifier(
                backendIdentifier: .zmx,
                validating: parsed.name
            )
            guard seen.insert(identifier).inserted else {
                throw SSHError.unknown("zmx returned a duplicate session identifier")
            }
            return RemoteSessionDescriptor(
                attachment: RemoteSessionAttachment(
                    identifier: identifier,
                    ownership: parsed.ownership
                ),
                attachedClientCount: parsed.attachedClientCount,
                containerCount: nil,
                cleanupDisposition: RemoteSessionCleanupDisposition(
                    attachedClientCount: parsed.attachedClientCount
                )
            )
        }
        switch scope {
        case .userVisible:
            return sessions
        case .managedCleanup:
            return sessions.filter { $0.attachment.ownership == .managed }
        }
    }

    private static func parseSessionLine(
        _ line: Substring
    ) throws -> (
        name: String,
        attachedClientCount: Int,
        ownership: RemoteSessionOwnership
    ) {
        let fields = sessionFields(line)
        guard let nameField = fields.first,
              nameField.hasPrefix("name=") else {
            throw SSHError.unknown("zmx returned invalid session metadata")
        }
        let clientFields = fields.filter { $0.hasPrefix("clients=") }
        guard clientFields.count == 1,
              let clientField = clientFields.first,
              let attachedClientCount = Int(clientField.dropFirst("clients=".count)),
              (0...maximumAttachedClientCount).contains(attachedClientCount) else {
            throw SSHError.unknown("zmx returned invalid client metadata")
        }
        return (
            name: String(nameField.dropFirst("name=".count)),
            attachedClientCount: attachedClientCount,
            ownership: fields.contains(Substring(
                ZmxRemoteSessionCommandBuilder.managedOwnershipLabel
            )) ? .managed : .external
        )
    }

    static func parseWorkingDirectory(
        for identifier: RemoteSessionIdentifier,
        in output: String
    ) -> String? {
        guard identifier.backendIdentifier == .zmx,
              output.utf8.count <= maximumOutputBytes else {
            return nil
        }
        let nameField = "name=\(identifier.rawValue)"
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { line in
            sessionFields(line).first
                == Substring(nameField)
        }) else {
            return nil
        }
        let fields = sessionFields(line)
        let path: String
        if let field = fields.first(where: { $0.hasPrefix("cwd=") }) {
            let rawURI = String(field.dropFirst("cwd=".count))
            guard let uri = URLComponents(string: rawURI),
                  uri.scheme?.lowercased() == "file",
                  uri.user == nil, uri.password == nil, uri.port == nil,
                  uri.query == nil, uri.fragment == nil,
                  let decodedPath = uri.percentEncodedPath.removingPercentEncoding else {
                return nil
            }
            path = decodedPath
        } else if let field = fields.first(where: { $0.hasPrefix("start_dir=") }) {
            // zmx 0.7 reports a plain path under its original field name.
            path = String(field.dropFirst("start_dir=".count))
        } else {
            return nil
        }
        guard path.hasPrefix("/"),
              (try? RemoteSessionExecutable(validating: path)) != nil else {
            return nil
        }
        return path
    }

    private static func sessionFields(_ line: Substring) -> [Substring] {
        // zmx indents list rows when ZMX_SESSION is unset. Preserve all field values.
        line.drop(while: { $0 == " " })
            .split(separator: "\t", omittingEmptySubsequences: false)
    }
}
