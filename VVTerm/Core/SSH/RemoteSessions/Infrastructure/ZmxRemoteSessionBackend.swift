import Foundation

nonisolated struct ZmxRemoteSessionBackend: RemoteSessionBackend {
    static let minimumVersion = RemoteSessionSemanticVersion(
        major: 0,
        minor: 7,
        patch: 0
    )

    let metadata = RemoteSessionBackendMetadata(
        identifier: .zmx,
        displayName: "zmx",
        installationGuideURL: URL(string: "https://zmx.sh")!,
        managedStartupCommandSupport: .supported
    )

    func availability(using client: SSHClient) async -> RemoteSessionAvailability {
        let environment = await client.remoteEnvironment()
        guard environment.platform != .windows,
              environment.shellProfile.family == .posix else {
            return .unsupportedEnvironment
        }

        do {
            let output = try await client.execute(
                ZmxRemoteSessionCommandBuilder.availabilityProbeCommand(),
                timeout: .seconds(8),
                maxOutputBytes: 8 * 1_024
            )
            try Task.checkCancellation()
            if output.contains(ZmxRemoteSessionCommandBuilder.missingMarker) {
                return .confirmedMissing
            }
            guard let result = ZmxRemoteSessionParser.parseProbe(output) else {
                return .indeterminate(.invalidResponse)
            }
            let probe = RemoteSessionProbe(
                backendIdentifier: .zmx,
                executable: result.executable,
                implementationVariant: "zmx",
                rawVersion: result.rawVersion,
                semanticVersion: result.semanticVersion,
                shellFamily: .posix,
                shellExecutable: environment.shellProfile.executableName
            )
            return result.semanticVersion >= Self.minimumVersion
                ? .available(probe)
                : .incompatible(probe)
        } catch {
            return .indeterminate(.resolve(error))
        }
    }

    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        try requireSupported(runtime)
        let output = try await client.executeChecked(
            ZmxRemoteSessionCommandBuilder.listCommand(runtime: runtime),
            timeout: .seconds(12),
            maxOutputBytes: ZmxRemoteSessionParser.maximumOutputBytes
        )
        return try ZmxRemoteSessionParser.parseSessionList(output, scope: scope)
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan {
        try requireSupported(runtime)
        guard request.attachment.identifier.backendIdentifier == .zmx else {
            throw SSHError.unknown("Remote session backend mismatch")
        }
        return RemoteSessionBackendLaunchPlan(
            command: try ZmxRemoteSessionCommandBuilder.launchCommand(
                request: request,
                runtime: runtime
            ),
            presenceProbe: try ZmxRemoteSessionCommandBuilder.presenceProbe(
                identifier: request.attachment.identifier,
                runtime: runtime
            )
        )
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws {
        guard identifier.backendIdentifier == .zmx else { throw SSHError.unknown("Remote session backend mismatch") }
        try requireSupported(runtime)
        let command = try ZmxRemoteSessionCommandBuilder.killCommand(
            identifier: identifier,
            runtime: runtime
        )
        try await client.executeChecked(
            command,
            timeout: .seconds(10),
            maxOutputBytes: 8 * 1_024
        )
    }

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String? {
        let identifier = attachment.identifier
        guard identifier.backendIdentifier == .zmx else { return nil }
        do {
            try requireSupported(runtime)
            let output = try await client.execute(
                ZmxRemoteSessionCommandBuilder.listCommand(
                    runtime: runtime
                ),
                timeout: .seconds(8),
                maxOutputBytes: ZmxRemoteSessionParser.maximumOutputBytes,
                timeoutScope: .command
            )
            return ZmxRemoteSessionParser.parseWorkingDirectory(
                for: identifier,
                in: output
            )
        } catch {
            return nil
        }
    }

    private func requireSupported(_ runtime: RemoteSessionRuntime) throws {
        let probe = runtime.probe
        guard probe.backendIdentifier == .zmx,
              probe.implementationVariant == "zmx",
              probe.shellFamily == .posix,
              let version = probe.semanticVersion,
              version >= Self.minimumVersion else {
            throw SSHError.unknown("Unsupported zmx runtime")
        }
    }

}
