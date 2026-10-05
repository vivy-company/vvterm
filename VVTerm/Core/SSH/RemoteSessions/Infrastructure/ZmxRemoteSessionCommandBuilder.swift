import Foundation

nonisolated enum ZmxRemoteSessionCommandBuilder {
    static let availableMarker = "__VVTERM_ZMX_OK__"
    static let missingMarker = "__VVTERM_ZMX_NO__"
    static let pathMarker = "__VVTERM_ZMX_PATH__"
    static let managedOwnershipLabel = "vvterm_owner=managed"

    private static let clearedEnvironment: Set<String> = [
        "ZMX_SESSION",
        "ZMX_SESSION_PREFIX"
    ]

    static func availabilityProbeCommand() -> String {
        let script = """
        \(RemoteTerminalBootstrap.shellPathExport());
        vvtermZmx="$(command -v zmx 2>/dev/null || true)";
        if [ -z "$vvtermZmx" ]; then
          for candidate in /opt/homebrew/bin/zmx /usr/local/bin/zmx /usr/bin/zmx /snap/bin/zmx "$HOME/.local/bin/zmx"; do
            if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then vvtermZmx="$candidate"; break; fi;
          done;
        fi;
        case "$vvtermZmx" in
          /*) ;;
          *) vvtermZmx="" ;;
        esac;
        if [ -n "$vvtermZmx" ] && [ -x "$vvtermZmx" ] && [ ! -d "$vvtermZmx" ]; then
          vvtermZmxVersion="$(env -u ZMX_SESSION -u ZMX_SESSION_PREFIX "$vvtermZmx" version 2>/dev/null | sed -n '1p')";
          if [ -n "$vvtermZmxVersion" ]; then
            printf '%s\n%s%s\n%s\n' '\(availableMarker)' '\(pathMarker)' "$vvtermZmx" "$vvtermZmxVersion";
          else
            printf '%s\n' '\(missingMarker)';
          fi;
        else
          printf '%s\n' '\(missingMarker)';
        fi
        """
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func listCommand(runtime: RemoteSessionRuntime) throws -> String {
        try render(arguments: ["list"], runtime: runtime)
    }

    static func launchCommand(
        request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        let attachment = request.intent.attachment
        let identifier = attachment.identifier.rawValue
        let list = try shortListCommand(runtime: runtime)
        let exists = exactPresenceExpression(
            listCommand: list,
            identifier: identifier
        )
        let ownerQuery = try render(
            arguments: ["get", identifier, "vvterm_owner"],
            runtime: runtime
        )
        // zmx list has no ownership filter. Query the label on this session.
        let isManaged = "vvtermZmxOwner=$(\(ownerQuery) 2>/dev/null) && [ \"$vvtermZmxOwner\" = 'managed' ]"
        let workingDirectory = request.workingDirectory == "~"
            ? nil
            : request.workingDirectory
        let attachExisting = try render(
            arguments: ["attach", identifier],
            workingDirectory: workingDirectory,
            runtime: runtime
        )
        let attached = quotedMarker(request.lifecycleEnvelope, .attached)
        let detached = quotedMarker(request.lifecycleEnvelope, .detached)
        let terminated = quotedMarker(request.lifecycleEnvelope, .terminated)
        let creationFailed = quotedMarker(request.lifecycleEnvelope, .creationFailed)
        let attachFailed = quotedMarker(request.lifecycleEnvelope, .attachFailed)

        let runAttachExisting = """
        printf '%s' \(attached)
        \(attachExisting)
        vvtermZmxStatus=$?
        if [ "$vvtermZmxStatus" -ne 0 ]; then
          printf '%s' \(attachFailed)
        elif \(exists); then
          printf '%s' \(detached)
        else
          printf '%s' \(terminated)
        fi
        """

        let script: String
        switch request.intent {
        case .attach:
            let preserveOwnership: String
            if attachment.ownership == .managed {
                preserveOwnership = try render(
                    arguments: ["set", identifier, managedOwnershipLabel],
                    runtime: runtime
                ) + " >/dev/null 2>&1"
            } else {
                preserveOwnership = ":"
            }
            script = """
            if \(exists) && \(preserveOwnership); then
              \(runAttachExisting)
            else
              printf '%s' \(attachFailed)
            fi
            """
        case .ensureManaged(_, let initialCommand):
            let createBase = try render(
                arguments: ["attach", identifier],
                workingDirectory: workingDirectory,
                runtime: runtime
            )
            let managedStartupScript = """
            \(RemoteTerminalBootstrap.shellQuoted(runtime.probe.executable.path)) set . \(RemoteTerminalBootstrap.shellQuoted(managedOwnershipLabel)) >/dev/null 2>&1 || exit 1
            printf '%s' \(attached)
            \(initialCommand ?? RemoteTerminalBootstrap.defaultLoginShellCommand())
            """
            let createManaged = "\(createBase) \(RemoteTerminalBootstrap.wrapPOSIXShellCommand(managedStartupScript))"
            script = """
            if \(isManaged); then
              \(runAttachExisting)
            elif \(exists); then
              printf '%s' \(creationFailed)
            else
              \(createManaged)
              vvtermZmxStatus=$?
              if [ "$vvtermZmxStatus" -ne 0 ]; then
                if \(exists); then printf '%s' \(attachFailed); else printf '%s' \(creationFailed); fi
              elif \(isManaged); then
                printf '%s' \(detached)
              elif \(exists); then
                printf '%s' \(creationFailed)
              else
                printf '%s' \(terminated)
              fi
            fi
            """
        }
        return RemoteTerminalBootstrap.wrapPOSIXShellCommand(script)
    }

    static func presenceProbe(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionPresenceProbe {
        let markerID = UUID().uuidString
        let existsMarker = "__VVTERM_SESSION_EXISTS_\(markerID)__"
        let missingMarker = "__VVTERM_SESSION_MISSING_\(markerID)__"
        let list = try shortListCommand(runtime: runtime)
        let presence = exactPresenceExpression(
            listCommand: list,
            identifier: identifier.rawValue
        )
        let script = """
        if \(presence); then
          printf '%s' \(RemoteTerminalBootstrap.shellQuoted(existsMarker))
        else
          printf '%s' \(RemoteTerminalBootstrap.shellQuoted(missingMarker))
        fi
        """
        return RemoteSessionPresenceProbe(
            command: RemoteTerminalBootstrap.wrapPOSIXShellCommand(script),
            existsMarker: existsMarker,
            missingMarker: missingMarker
        )
    }

    static func killCommand(
        identifier: RemoteSessionIdentifier,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        try render(
            arguments: ["kill", identifier.rawValue, "--force"],
            runtime: runtime
        )
    }

    private static func render(
        arguments: [String],
        workingDirectory: String? = nil,
        runtime: RemoteSessionRuntime
    ) throws -> String {
        guard runtime.probe.backendIdentifier == .zmx,
              runtime.probe.shellFamily == .posix else {
            throw SSHError.unknown("zmx requires a POSIX remote shell")
        }
        return try RemoteSessionCommandRenderer.render(
            RemoteSessionCommandPlan(
                executable: runtime.probe.executable,
                arguments: arguments,
                environmentRemovals: clearedEnvironment,
                workingDirectory: workingDirectory
            ),
            for: .posix
        )
    }

    private static func exactPresenceExpression(
        listCommand: String,
        identifier: String
    ) -> String {
        "\(listCommand) | grep -Fqx -- \(RemoteTerminalBootstrap.shellQuoted(identifier))"
    }

    private static func shortListCommand(runtime: RemoteSessionRuntime) throws -> String {
        try render(arguments: ["list", "--short"], runtime: runtime)
    }

    private static func quotedMarker(
        _ envelope: RemoteSessionLifecycleEnvelope,
        _ event: RemoteSessionEvent
    ) -> String {
        RemoteTerminalBootstrap.shellQuoted(
            RemoteSessionLifecycleMarker.sequence(envelope: envelope, event: event)
        )
    }
}
