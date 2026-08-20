import Foundation

nonisolated struct MoshFallbackDiagnostics: Equatable, Sendable {
    struct AppContext: Equatable, Sendable {
        let version: String
        let platform: String

        static var current: Self {
            let shortVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown"
            let build = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
            let version = build.map { "\(shortVersion) (\($0))" } ?? shortVersion
            #if os(iOS)
            let platformName = "iOS"
            #elseif os(macOS)
            let platformName = "macOS"
            #else
            let platformName = "Apple"
            #endif
            return Self(
                version: version,
                platform: "\(platformName) \(Foundation.ProcessInfo.processInfo.operatingSystemVersionString)"
            )
        }
    }

    struct StageDuration: Equatable, Sendable {
        let stage: SSHStartupStage
        let milliseconds: Int
    }

    let appContext: AppContext
    let selectedTransport: ShellTransport
    let actualTransport: ShellTransport
    let failureCategory: MoshFallbackReason
    let failureStage: SSHStartupStage
    let endpointClass: String
    let portClass: String
    let stageDurations: [StageDuration]
    let fallbackResult: String

    static func make(
        reason: MoshFallbackReason,
        events: [SSHStartupTrace.Event],
        appContext: AppContext = .current
    ) -> Self {
        let endpointClass = events.last(where: { $0.stage == .moshEndpoint })
            .flatMap { allowedEndpointClass($0.detail) } ?? "unavailable"
        let portClass = events.last(where: { $0.stage == .moshBootstrap })
            .flatMap { allowedPortClass($0.detail) } ?? "unavailable"
        let durations = diagnosticStages.compactMap { stage in
            events.last(where: { $0.stage == stage }).map {
                StageDuration(stage: stage, milliseconds: max(0, $0.stageMilliseconds))
            }
        }

        return Self(
            appContext: appContext,
            selectedTransport: .mosh,
            actualTransport: .sshFallback,
            failureCategory: reason,
            failureStage: failureStage(for: reason),
            endpointClass: endpointClass,
            portClass: portClass,
            stageDurations: durations,
            fallbackResult: "connected"
        )
    }

    var copyText: String {
        var lines = [
            "VVTerm Mosh Fallback Diagnostics",
            "app_version=\(appContext.version)",
            "platform=\(appContext.platform)",
            "selected_transport=\(selectedTransport.rawValue)",
            "actual_transport=\(actualTransport.rawValue)",
            "failure_category=\(failureCategory.rawValue)",
            "failure_stage=\(failureStage.rawValue)",
            "endpoint_class=\(endpointClass)",
            "port_class=\(portClass)",
            "fallback_result=\(fallbackResult)",
            "stage_durations_ms:"
        ]
        if stageDurations.isEmpty {
            lines.append("- unavailable")
        } else {
            lines.append(contentsOf: stageDurations.map {
                "- \($0.stage.rawValue)=\($0.milliseconds)"
            })
        }
        return lines.joined(separator: "\n")
    }

    private static let diagnosticStages: [SSHStartupStage] = [
        .remoteEnvironment,
        .terminalType,
        .moshBootstrap,
        .moshEndpoint,
        .moshUDPSession,
        .sshFallback,
    ]

    private static func failureStage(for reason: MoshFallbackReason) -> SSHStartupStage {
        switch reason {
        case .unsupportedRemoteCapabilities:
            return .remoteEnvironment
        case .serverMissing, .serverRuntimeBroken, .bootstrapFailed:
            return .moshBootstrap
        case .invalidEndpoint:
            return .moshEndpoint
        case .udpTimeout, .clientSessionFailed, .sessionFailed:
            return .moshUDPSession
        }
    }

    private static func allowedEndpointClass(_ value: String) -> String? {
        switch value {
        case "configured", "ssh_peer": value
        default: nil
        }
    }

    private static func allowedPortClass(_ value: String) -> String? {
        switch value {
        case RemoteMoshManager.PortClass.privileged.rawValue,
             RemoteMoshManager.PortClass.standardMoshRange.rawValue,
             RemoteMoshManager.PortClass.otherUnprivileged.rawValue:
            value
        default:
            nil
        }
    }
}
