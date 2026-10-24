import CloudKit
import Foundation
import os.log

nonisolated enum ServerCloudKitRecordCodec {
    static let recordType = "Server"
    static let recordKeys = [
        "workspaceId", "name", "host", "port", "eternalTerminalPort", "username",
        "connectionMode", "authMethod", "transportConfiguration", "teleportConfiguration", "cloudflareAccessMode",
        "iconSelection", "detectedSystemKind", "detectedSystemDisplayName",
        "appleHardwareModelIdentifier",
        "cloudflareTeamDomainOverride", "cloudflareAppDomainOverride", "tags", "notes",
        "wakeOnLANConfiguration", "autoWakeOnLANEnabled",
        "lastConnected", "isFavorite", "requiresBiometricUnlock", "tmuxEnabledOverride",
        "tmuxStartupBehaviorOverride",
        "remoteSessionEnabledOverride", "remoteSessionBackendIdentifier",
        "remoteSessionStartupBehaviorOverride", "remoteShellStartupCommand",
        "createdAt", "updatedAt", "environment"
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
        let connectionMode: SSHConnectionMode
        if let value = record["connectionMode"] {
            guard let rawValue = value as? String else {
                logger.error("Server \(id): invalid transport type")
                return nil
            }
            connectionMode = SSHConnectionMode(rawValue: rawValue)
        } else {
            connectionMode = .standard
        }
        let transportConfiguration: ServerTransportConfiguration?
        if let value = record["transportConfiguration"] {
            guard let data = value as? Data,
                  data.count <= ServerTransportConfiguration.maximumEncodedSize,
                  let configuration = try? JSONDecoder().decode(
                    ServerTransportConfiguration.self, from: data
                  ) else {
                logger.error("Server \(id): invalid transport configuration")
                return nil
            }
            transportConfiguration = configuration
        } else if connectionMode == .teleport, let value = record["teleportConfiguration"] {
            guard let data = value as? Data,
                  data.count <= ServerTransportConfiguration.maximumSettingsSize,
                  let configuration = try? JSONDecoder().decode(
                    TeleportServerConfiguration.self, from: data
                  ) else {
                logger.error("Server \(id): invalid saved transport configuration")
                return nil
            }
            transportConfiguration = .teleport(configuration)
        } else {
            transportConfiguration = nil
        }
        guard connectionMode != .teleport || transportConfiguration != nil else {
            logger.error("Server \(id): missing transport configuration")
            return nil
        }
        let authMethod: AuthMethod?
        if connectionMode.usesSSHAuthentication {
            guard let rawValue = record["authMethod"] as? String,
                  let method = AuthMethod(rawValue: rawValue) else {
                logger.error("Server \(id): invalid authMethod")
                return nil
            }
            authMethod = method
        } else {
            authMethod = nil
        }

        let environment: ServerEnvironment
        if let data = record["environment"] as? Data,
           let decoded = try? JSONDecoder().decode(ServerEnvironment.self, from: data) {
            environment = decoded
        } else {
            environment = .production
        }

        let cloudflareAccessMode = (record["cloudflareAccessMode"] as? String)
            .flatMap(CloudflareAccessMode.init(rawValue:))
        let legacyStartupBehavior = (record["tmuxStartupBehaviorOverride"] as? String)
            .flatMap(RemoteSessionStartupBehavior.init(persistedRawValue:))
        let backendIdentifier = RemoteSessionBackendIdentifier(
            rawValue: record["remoteSessionBackendIdentifier"] as? String
                ?? RemoteSessionBackendIdentifier.tmux.rawValue
        )
        let currentEnabledOverride = record["remoteSessionEnabledOverride"] as? Bool
        let currentStartupBehavior = (
            record["remoteSessionStartupBehaviorOverride"] as? String
        ).flatMap(RemoteSessionStartupBehavior.init(persistedRawValue:))
        let enabledOverride = backendIdentifier == .tmux
            ? (record["tmuxEnabledOverride"] as? Bool) ?? currentEnabledOverride
            : currentEnabledOverride
        let startupBehavior = backendIdentifier == .tmux
            ? (legacyStartupBehavior ?? currentStartupBehavior)
            : currentStartupBehavior
        let updatedAt = record["updatedAt"] as? Date ?? now
        let wakeOnLANConfiguration = (record["wakeOnLANConfiguration"] as? Data)
            .flatMap { try? JSONDecoder().decode(WakeOnLANConfiguration.self, from: $0) }
        let detectedSystemIdentity = (record["detectedSystemKind"] as? String)
            .flatMap(RemoteSystemKind.init(rawValue:))
            .map { kind in
                RemoteSystemIdentity(
                    kind: kind,
                    displayName: record["detectedSystemDisplayName"] as? String,
                    appleHardwareModelIdentifier: (record["appleHardwareModelIdentifier"] as? String)
                        .flatMap(AppleHardwareModelIdentifier.init(rawValue:))
                )
            }

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
            transportConfiguration: transportConfiguration,
            iconSelection: ServerIconSelection(
                persistedValue: record["iconSelection"] as? String
            ),
            detectedSystemIdentity: detectedSystemIdentity,
            cloudflareAccessMode: cloudflareAccessMode,
            cloudflareTeamDomainOverride: record["cloudflareTeamDomainOverride"] as? String,
            cloudflareAppDomainOverride: record["cloudflareAppDomainOverride"] as? String,
            wakeOnLANConfiguration: wakeOnLANConfiguration,
            autoWakeOnLANEnabled: record["autoWakeOnLANEnabled"] as? Bool ?? false,
            tags: record["tags"] as? [String] ?? [],
            notes: record["notes"] as? String,
            lastConnected: record["lastConnected"] as? Date,
            isFavorite: record["isFavorite"] as? Bool ?? false,
            requiresBiometricUnlock: record["requiresBiometricUnlock"] as? Bool ?? false,
            remoteSessionEnabledOverride: enabledOverride,
            remoteSessionBackendIdentifier: backendIdentifier,
            remoteSessionStartupBehaviorOverride: startupBehavior,
            remoteShellStartupCommand: record["remoteShellStartupCommand"] as? String,
            createdAt: record["createdAt"] as? Date ?? now,
            updatedAt: updatedAt
        )
    }

    static func record(
        for server: Server,
        in zoneID: CKRecordZone.ID,
        now: Date
    ) throws -> CKRecord {
        if server.connectionMode == .teleport, server.transportConfiguration == nil {
            throw EncodingError.invalidValue(server, .init(
                codingPath: [], debugDescription: "Teleport requires transport settings."
            ))
        }
        let transportData = try server.transportConfiguration.map { try JSONEncoder().encode($0) }
        guard transportData.map({ $0.count <= ServerTransportConfiguration.maximumEncodedSize }) ?? true else {
            throw EncodingError.invalidValue(server, .init(
                codingPath: [], debugDescription: "Transport configuration exceeds its size limit."
            ))
        }
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
        record["authMethod"] = server.authMethod?.rawValue
        // Assign nil too: changed-keys updates must remove settings after a transport change.
        record["transportConfiguration"] = transportData
        record["teleportConfiguration"] = nil
        record["iconSelection"] = server.iconSelection.persistedValue
        record["detectedSystemKind"] = server.detectedSystemIdentity?.kind.rawValue
        record["detectedSystemDisplayName"] = server.detectedSystemIdentity?.displayName
        record["appleHardwareModelIdentifier"] =
            server.detectedSystemIdentity?.appleHardwareModelIdentifier?.rawValue
        record["cloudflareAccessMode"] = server.cloudflareAccessMode?.rawValue
        record["cloudflareTeamDomainOverride"] = nonempty(server.cloudflareTeamDomainOverride)
        record["cloudflareAppDomainOverride"] = nonempty(server.cloudflareAppDomainOverride)
        if let configuration = server.wakeOnLANConfiguration,
           let encodedConfiguration = try? JSONEncoder().encode(configuration) {
            record["wakeOnLANConfiguration"] = encodedConfiguration
        }
        record["autoWakeOnLANEnabled"] = server.autoWakeOnLANEnabled
        if !server.tags.isEmpty {
            record["tags"] = server.tags
        }
        record["notes"] = server.notes
        record["lastConnected"] = server.lastConnected
        record["isFavorite"] = server.isFavorite
        record["requiresBiometricUnlock"] = server.requiresBiometricUnlock
        record["remoteSessionEnabledOverride"] = server.remoteSessionEnabledOverride
        record["remoteSessionBackendIdentifier"] = server.remoteSessionBackendIdentifier.rawValue
        record["remoteSessionStartupBehaviorOverride"] =
            server.remoteSessionStartupBehaviorOverride?.rawValue
        record["tmuxEnabledOverride"] = legacyTmuxEnabledOverride(for: server)
        record["tmuxStartupBehaviorOverride"] = legacyTmuxStartupBehavior(for: server)
        record["remoteShellStartupCommand"] = server.remoteShellStartupAction?.command
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

    private static func legacyTmuxEnabledOverride(for server: Server) -> Bool? {
        server.remoteSessionBackendIdentifier == .tmux
            ? server.remoteSessionEnabledOverride
            : false
    }

    private static func legacyTmuxStartupBehavior(for server: Server) -> String? {
        guard server.remoteSessionBackendIdentifier == .tmux else {
            return "skipTmux"
        }
        return switch server.remoteSessionStartupBehaviorOverride {
        case .createManaged: "vvtermManaged"
        case .ask: "askEveryTime"
        case .plainShell: "skipTmux"
        case nil: nil
        }
    }
}
