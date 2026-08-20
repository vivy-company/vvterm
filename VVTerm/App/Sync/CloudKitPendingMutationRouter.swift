import Foundation

@MainActor
final class CloudKitPendingMutationRouter: PendingCloudKitMutationHandling {
    private let serverCloud: any ServerRemoteMutationClient
    private let terminalThemeCloud: any TerminalThemeCloudMutationClient
    private let terminalAccessoryHandler: TerminalAccessoryPendingMutationHandler
    private let statsPreferencesHandler: StatsPreferencesPendingMutationHandler

    init(
        serverCloud: any ServerRemoteMutationClient,
        terminalThemeCloud: any TerminalThemeCloudMutationClient,
        terminalAccessoryHandler: TerminalAccessoryPendingMutationHandler,
        statsPreferencesHandler: StatsPreferencesPendingMutationHandler
    ) {
        self.serverCloud = serverCloud
        self.terminalThemeCloud = terminalThemeCloud
        self.terminalAccessoryHandler = terminalAccessoryHandler
        self.statsPreferencesHandler = statsPreferencesHandler
    }

    func handle(_ mutation: PendingCloudKitMutation) async throws {
        if let payload = try ServerPendingCloudKitPayloadCodec.decode(mutation.payload) {
            switch payload {
            case .serverUpsert(let server):
                try await serverCloud.saveServer(server)
            case .serverDelete(let server):
                try await serverCloud.deleteServer(server)
            case .workspaceUpsert(let workspace):
                try await serverCloud.saveWorkspace(workspace)
            case .workspaceDelete(let workspace):
                try await serverCloud.deleteWorkspace(workspace)
            }
            return
        }

        if let theme = try TerminalThemePendingCloudKitPayloadCodec.decodeTheme(mutation.payload) {
            try await terminalThemeCloud.saveTerminalTheme(theme)
            return
        }

        if let preference = try TerminalThemePendingCloudKitPayloadCodec.decodePreference(
            mutation.payload
        ) {
            try await terminalThemeCloud.saveTerminalThemePreference(preference)
            return
        }

        if let profile = try TerminalAccessoryPendingCloudKitPayloadCodec.decode(mutation.payload) {
            try await terminalAccessoryHandler.handle(profile)
            return
        }

        if let preferences = try StatsPreferencesPendingCloudKitPayloadCodec.decode(mutation.payload) {
            try await statsPreferencesHandler.handle(preferences)
            return
        }

        throw CloudKitPendingMutationRoutingError.unsupportedPayload(
            entityType: mutation.payload.entityType,
            operation: mutation.payload.operation
        )
    }
}

private enum CloudKitPendingMutationRoutingError: LocalizedError {
    case unsupportedPayload(
        entityType: String,
        operation: PendingCloudKitMutationOperation
    )

    var errorDescription: String? {
        switch self {
        case .unsupportedPayload(let entityType, let operation):
            return "Unsupported pending CloudKit mutation: \(entityType) \(operation.rawValue)."
        }
    }
}
