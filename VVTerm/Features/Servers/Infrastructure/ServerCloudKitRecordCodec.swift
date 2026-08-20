import CloudKit
import Foundation
import os.log

nonisolated enum ServerCloudKitRecordCodec {
    static let recordType = "Server"
    static let recordKeys = [
        "workspaceId", "name", "host", "port", "eternalTerminalPort", "username",
        "connectionMode", "authMethod", "cloudflareAccessMode",
        "cloudflareTeamDomainOverride", "cloudflareAppDomainOverride", "tags", "notes",
        "lastConnected", "isFavorite", "requiresBiometricUnlock", "tmuxEnabledOverride",
        "tmuxStartupBehaviorOverride", "createdAt", "updatedAt", "environment"
    ]

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "Server.CloudKit"
    )

    static func server(from record: CKRecord, now: Date) -> Server? {
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            logger.error("Failed to decode server: invalid recordID '\(record.recordID.recordName)'")
            return nil
        }
        guard let workspaceIDString = record["workspaceId"] as? String,
              let workspaceID = UUID(uuidString: workspaceIDString) else {
            logger.error("Server \(id): missing or invalid workspaceId")
            return nil
        }
        guard let name = record["name"] as? String,
              let host = record["host"] as? String,
              let username = record["username"] as? String else {
            logger.error("Server \(id): missing required text fields")
            return nil
        }
        guard let port = validPort(record["port"]) else {
            logger.error("Server \(id): missing or invalid port")
            return nil
        }
        guard let authMethodRaw = record["authMethod"] as? String,
              let authMethod = AuthMethod(rawValue: authMethodRaw) else {
            logger.error("Server \(id): invalid authMethod")
            return nil
        }

        let environment: ServerEnvironment
        if let data = record["environment"] as? Data,
           let decoded = try? JSONDecoder().decode(ServerEnvironment.self, from: data) {
            environment = decoded
        } else {
            environment = .production
        }

        let connectionMode = (record["connectionMode"] as? String)
            .flatMap(SSHConnectionMode.init(rawValue:)) ?? .standard
        let cloudflareAccessMode = (record["cloudflareAccessMode"] as? String)
            .flatMap(CloudflareAccessMode.init(rawValue:))

        return Server(
            id: id,
            workspaceId: workspaceID,
            environment: environment,
            name: name,
            host: host,
            port: port,
            eternalTerminalPort: validPort(record["eternalTerminalPort"]) ?? 2022,
            username: username,
            connectionMode: connectionMode,
            authMethod: authMethod,
            cloudflareAccessMode: cloudflareAccessMode,
            cloudflareTeamDomainOverride: record["cloudflareTeamDomainOverride"] as? String,
            cloudflareAppDomainOverride: record["cloudflareAppDomainOverride"] as? String,
            tags: record["tags"] as? [String] ?? [],
            notes: record["notes"] as? String,
            lastConnected: record["lastConnected"] as? Date,
            isFavorite: record["isFavorite"] as? Bool ?? false,
            requiresBiometricUnlock: record["requiresBiometricUnlock"] as? Bool ?? false,
            tmuxEnabledOverride: record["tmuxEnabledOverride"] as? Bool,
            tmuxStartupBehaviorOverride: (record["tmuxStartupBehaviorOverride"] as? String)
                .flatMap(TmuxStartupBehavior.init(rawValue:)),
            createdAt: record["createdAt"] as? Date ?? now,
            updatedAt: record["updatedAt"] as? Date ?? now
        )
    }

    static func record(
        for server: Server,
        in zoneID: CKRecordZone.ID,
        now: Date
    ) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: server.id.uuidString,
            zoneID: zoneID
        )
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["workspaceId"] = server.workspaceId.uuidString
        record["name"] = server.name
        record["host"] = server.host
        record["port"] = server.port
        record["eternalTerminalPort"] = server.eternalTerminalPort
        record["username"] = server.username
        record["connectionMode"] = server.connectionMode == .standard
            ? nil
            : server.connectionMode.rawValue
        record["authMethod"] = server.authMethod.rawValue
        record["cloudflareAccessMode"] = server.cloudflareAccessMode?.rawValue
        record["cloudflareTeamDomainOverride"] = nonempty(server.cloudflareTeamDomainOverride)
        record["cloudflareAppDomainOverride"] = nonempty(server.cloudflareAppDomainOverride)
        if !server.tags.isEmpty {
            record["tags"] = server.tags
        }
        record["notes"] = server.notes
        record["lastConnected"] = server.lastConnected
        record["isFavorite"] = server.isFavorite
        record["requiresBiometricUnlock"] = server.requiresBiometricUnlock
        record["tmuxEnabledOverride"] = server.tmuxEnabledOverride
        record["tmuxStartupBehaviorOverride"] = server.tmuxStartupBehaviorOverride?.rawValue
        record["createdAt"] = server.createdAt
        record["updatedAt"] = now
        if let environment = try? JSONEncoder().encode(server.environment) {
            record["environment"] = environment
        }
        return record
    }

    private static func validPort(_ value: Any?) -> Int? {
        if let value = value as? Int, (1...65_535).contains(value) {
            return value
        }
        if let value = value as? NSNumber, (1...65_535).contains(value.intValue) {
            return value.intValue
        }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
