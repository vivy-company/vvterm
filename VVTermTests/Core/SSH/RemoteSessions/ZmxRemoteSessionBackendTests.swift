import Foundation
import Testing
@testable import VVTerm

struct ZmxRemoteSessionBackendTests {
    @Test
    func probeParsesAbsoluteExecutableAndMinimumVersion() throws {
        let result = try #require(ZmxRemoteSessionParser.parseProbe("""
        noise
        __VVTERM_ZMX_OK__
        __VVTERM_ZMX_PATH__/usr/local/bin/zmx
        zmx 0.7.0
        """))

        #expect(result.executable.path == "/usr/local/bin/zmx")
        #expect(result.rawVersion == "zmx 0.7.0")
        #expect(result.semanticVersion == ZmxRemoteSessionBackend.minimumVersion)
    }

    @Test(arguments: [
        "__VVTERM_ZMX_OK__\n__VVTERM_ZMX_PATH__zmx\nzmx 0.7.0",
        "__VVTERM_ZMX_OK__\n__VVTERM_ZMX_PATH__/usr/bin/zmx\nunknown",
        "__VVTERM_ZMX_PATH__/usr/bin/zmx\nzmx 0.7.0"
    ])
    func probeRejectsUntrustedOrIncompleteOutput(_ output: String) {
        #expect(ZmxRemoteSessionParser.parseProbe(output) == nil)
    }

    @Test(arguments: ["", "  "])
    func discoveryPreservesBackendAndAttachedClientMetadata(_ prefix: String) throws {
        let sessions = try ZmxRemoteSessionParser.parseSessionList("""
        \(prefix)name=alpha\tpid=10\tclients=0\tcreated=1\tstart_dir=/tmp
        \(prefix)name=team session\tpid=11\tclients=2\tcreated=2\tstart_dir=/srv/team
        """)

        #expect(sessions.map(\.id.backendIdentifier) == [.zmx, .zmx])
        #expect(sessions.map(\.id.rawValue) == ["alpha", "team session"])
        #expect(sessions.map(\.attachedClientCount) == [0, 2])
        #expect(sessions.map(\.cleanupDisposition) == [.safeToDelete, .inUse])
        #expect(sessions.map(\.attachment.ownership) == [.external, .external])
        #expect(sessions.allSatisfy { $0.containerCount == nil })
    }

    @Test
    func explicitLabelIsTheOnlyManagedOwnershipSignal() throws {
        let sessions = try ZmxRemoteSessionParser.parseSessionList("""
        name=vvterm-user-created\tclients=0
        name=plain-name\tclients=0\tvvterm_owner=managed
        """)

        #expect(sessions.map(\.attachment.ownership) == [.external, .managed])
    }

    @Test
    func indentedMetadataPreservesFieldSpacesAndOwnership() throws {
        let output = "  name= team session \tclients=0\tvvterm_owner=managed\tstart_dir=/srv/team "
        let session = try #require(ZmxRemoteSessionParser.parseSessionList(output).first)

        #expect(session.id.rawValue == " team session ")
        #expect(session.attachment.ownership == .managed)
        #expect(ZmxRemoteSessionParser.parseWorkingDirectory(for: session.id, in: output) == "/srv/team ")
    }

    @Test(arguments: ["", "  "])
    func fullListMetadataProvidesTheSessionStartDirectory(_ prefix: String) throws {
        let identifier = try identifier("team session")
        let output = """
        \(prefix)name=other\tpid=10\tclients=0\tcreated=1\tstart_dir=/tmp
        \(prefix)name=team session\tpid=11\tclients=1\tcreated=2\tstart_dir=/srv/team project\trole=dev
        """

        #expect(
            ZmxRemoteSessionParser.parseWorkingDirectory(for: identifier, in: output)
                == "/srv/team project"
        )
        #expect(ZmxRemoteSessionParser.parseWorkingDirectory(
            for: try self.identifier("missing"),
            in: output
        ) == nil)
        let listCommand = try ZmxRemoteSessionCommandBuilder.listCommand(
            runtime: runtime()
        )
        #expect(listCommand.contains("'list'"))
        #expect(!listCommand.contains("'--short'"))
    }

    @Test
    func listUsesSupportedFullMetadataQuery() throws {
        let userVisible = try ZmxRemoteSessionCommandBuilder.listCommand(
            runtime: runtime()
        )
        #expect(userVisible.contains("'list'"))
        #expect(!userVisible.contains("'--short'"))
        #expect(!userVisible.contains("'--where'"))
    }

    @Test(arguments: ["", "  "])
    func currentDirectoryDecodesRemoteFileURI(_ prefix: String) throws {
        let output = "\(prefix)name=team session\tclients=0\tcwd=file://FlyingNAS/srv/team%20project/%E4%B8%AD"
        #expect(ZmxRemoteSessionParser.parseWorkingDirectory(
            for: try identifier("team session"), in: output
        ) == "/srv/team project/中")
    }

    @Test
    func managedLaunchUsesSupportedOwnershipQuery() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(identifier: try identifier("shared"), initialCommand: nil),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
        let command = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request, runtime: runtime()
        )
        #expect(!command.contains("--where"))
        #expect(command.contains("'get' 'shared' 'vvterm_owner'"))
    }

    @Test
    func cleanupFiltersMixedOwnershipAfterValidatingAllRows() throws {
        let output = """
          name=main\tclients=0\tcwd=file://host/tmp
          name=owned\tclients=0\tvvterm_owner=managed
          name=vvterm-user-created\tclients=0\tvvterm_owner=other
          name=active-owned\tclients=2\tvvterm_owner=managed
        """
        let visible = try ZmxRemoteSessionParser.parseSessionList(output, scope: .userVisible)
        let cleanup = try ZmxRemoteSessionParser.parseSessionList(output, scope: .managedCleanup)
        #expect(visible.count == 4)
        #expect(cleanup.map(\.id.rawValue) == ["owned", "active-owned"])
        #expect(cleanup.map(\.cleanupDisposition) == [.safeToDelete, .inUse])
        #expect(try ZmxRemoteSessionParser.parseSessionList(
            "name=main\tclients=0", scope: .managedCleanup
        ).isEmpty)
        #expect(throws: SSHError.self) {
            try ZmxRemoteSessionParser.parseSessionList(
                output + "\nname=broken\tclients=invalid", scope: .managedCleanup
            )
        }
    }

    @Test(arguments: [
        "file://host/srv/a%25b%23c", "file:///srv/a%25b%23c"
    ])
    func currentDirectoryPrefersCwdAndDecodesOnce(_ uri: String) throws {
        let output = "name=main\tclients=0\tstart_dir=/old\tcwd=\(uri)"
        #expect(ZmxRemoteSessionParser.parseWorkingDirectory(
            for: try identifier("main"), in: output
        ) == "/srv/a%b#c")
    }

    @Test(arguments: [
        "https://host/tmp", "relative", "file:relative", "file://host",
        "file://user@host/tmp", "file://host/tmp?query", "file://host/tmp#fragment",
        "file://host/tmp/%00", "file://host/tmp/%0A", "file://host/tmp/%FF"
    ])
    func currentDirectoryRejectsInvalidCwdWithoutUsingStaleStartDirectory(_ uri: String) throws {
        #expect(ZmxRemoteSessionParser.parseWorkingDirectory(
            for: try identifier("main"),
            in: "name=main\tclients=0\tstart_dir=/old\tcwd=\(uri)"
        ) == nil)
    }

    #if os(macOS)
    @Test(arguments: ["external", "wrong-owner", "query-failure", "managed", "missing"])
    func managedLaunchPreservesExternalSessions(_ mode: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zmx")
        let fixture = #"""
        #!/bin/sh
        state=$(dirname "$0")
        printf '%s\n' "$*" >> "$state/calls"
        case "$1" in
          list) if [ -f "$state/exists" ]; then printf '%s\n' shared; fi ;;
          get)
            case "$(cat "$state/owner")" in
              managed) printf managed ;;
              query-failure) printf managed; exit 1 ;;
              wrong-owner) printf other ;;
              *) exit 1 ;;
            esac ;;
          attach)
            touch "$state/exists"
            shift 2
            if [ "$#" -gt 0 ]; then "$@"; fi ;;
          set) printf managed > "$state/owner" ;;
          *) exit 1 ;;
        esac
        """#
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try mode.write(to: directory.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
        if mode != "missing" {
            try "".write(to: directory.appendingPathComponent("exists"), atomically: true, encoding: .utf8)
        }
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(identifier: try identifier("shared"), initialCommand: ":"),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )
        let command = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request, runtime: runtime(executablePath: executable.path)
        )
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let calls = try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        let mayAttach = mode == "managed" || mode == "missing"
        #expect(process.terminationStatus == 0)
        #expect(calls.contains("attach shared") == mayAttach)
        #expect(calls.contains("set . vvterm_owner=managed") == (mode == "missing"))
        #expect(output.contains(RemoteSessionLifecycleMarker.sequence(
            envelope: deterministicRemoteSessionLifecycleEnvelope,
            event: mayAttach ? .detached : .creationFailed
        )))
    }
    #endif

    @Test
    func managedNamesFitZmxSocketBudgetAndRemainDeviceScoped() throws {
        let backend = ZmxRemoteSessionBackend()
        let entityID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = try backend.managedIdentifier(
            deviceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API"
        )
        let second = try backend.managedIdentifier(
            deviceID: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            entityID: entityID,
            serverName: "Prod API"
        )

        #expect(first.rawValue.hasPrefix("vvterm-prod-d"))
        #expect(first.rawValue.utf8.count <= RemoteSessionManagedIdentifierPolicy.maximumIdentifierLength)
        #expect(first != second)
    }

    @Test
    func discoveryRejectsDuplicatesAndBoundOverruns() {
        #expect(throws: SSHError.self) {
            try ZmxRemoteSessionParser.parseSessionList("""
            name=same\tclients=0
            name=same\tclients=0
            """)
        }
        for malformed in [
            "  unexpected\tclients=0",
            "name=missing-clients\tpid=1",
            "name=negative\tclients=-1",
            "name=invalid\tclients=unknown"
        ] {
            #expect(throws: SSHError.self) {
                try ZmxRemoteSessionParser.parseSessionList(malformed)
            }
        }
        let tooMany = (0...ZmxRemoteSessionParser.maximumSessionCount)
            .map { "name=session-\($0)\tclients=0" }
            .joined(separator: "\n")
        #expect(throws: SSHError.self) {
            try ZmxRemoteSessionParser.parseSessionList(tooMany)
        }
        #expect(throws: SSHError.self) {
            try ZmxRemoteSessionParser.parseSessionList(
                String(repeating: "x", count: ZmxRemoteSessionParser.maximumOutputBytes + 1)
            )
        }
    }

    @Test
    func launchUsesTypedArgumentsAbsolutePathAndCleanEnvironment() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try identifier("team '$(touch no)"),
                initialCommand: "printf startup"
            ),
            workingDirectory: "/srv/$(touch no)",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let plan = try ZmxRemoteSessionBackend().launchPlan(
            for: request,
            runtime: runtime()
        )

        #expect(plan.command.contains("env '-u' 'ZMX_SESSION' '-u' 'ZMX_SESSION_PREFIX'"))
        #expect(plan.command.contains("'/opt/homebrew/bin/zmx' 'attach'"))
        #expect(plan.command.contains("set . 'vvterm_owner=managed'"))
        #expect(plan.command.contains("printf startup"))
        #expect(plan.command.contains("grep -Fqx --"))
        #expect(plan.command.contains(#"\$(touch no)"#))
        #expect(!plan.command.contains(#"; $(touch no)"#))
        #expect(plan.command.contains(RemoteSessionLifecycleMarker.sequence(
            envelope: deterministicRemoteSessionLifecycleEnvelope,
            event: .detached
        )))
        #expect(plan.presenceProbe.sessionExists(in: plan.presenceProbe.existsMarker) == true)
        #expect(plan.presenceProbe.sessionExists(in: plan.presenceProbe.missingMarker) == false)
    }

    @Test
    func managedCreationAcceptsAMultilineInitialCommand() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(
                identifier: try identifier("multiline"),
                initialCommand: "cd /srv/project\nprintf '%s\\n' ready"
            ),
            workingDirectory: "/srv/project",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let command = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )

        #expect(command.contains("/bin/sh -lc"))
        #expect(command.contains("cd /srv/project"))
        #expect(command.contains("ready"))
    }

    @Test
    func attachExistingChecksPresenceAndKillUsesForce() throws {
        let attachment = RemoteSessionAttachment(
            identifier: try identifier("shared"),
            ownership: .external
        )
        let request = RemoteSessionLaunchRequest(
            intent: .attach(attachment),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let launch = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )
        let kill = try ZmxRemoteSessionCommandBuilder.killCommand(
            identifier: attachment.identifier,
            runtime: runtime()
        )

        #expect(launch.contains("if env '-u' 'ZMX_SESSION'"))
        #expect(!launch.contains("set . 'vvterm_owner=managed'"))
        #expect(!launch.contains("printf startup"))
        #expect(kill.contains("'kill' 'shared' '--force'"))
    }

    @Test
    func managedReattachRestoresItsExplicitOwnershipLabel() throws {
        let request = RemoteSessionLaunchRequest(
            intent: .attach(RemoteSessionAttachment(
                identifier: try identifier("legacy-managed"),
                ownership: .managed
            )),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let launch = try ZmxRemoteSessionCommandBuilder.launchCommand(
            request: request,
            runtime: runtime()
        )

        #expect(launch.contains("'set' 'legacy-managed' 'vvterm_owner=managed'"))
        #expect(!launch.contains("printf startup"))
    }

    @Test
    func tmuxAdapterUsesResolvedAbsoluteExecutable() throws {
        let identifier = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "managed"
        )
        let runtime = RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try RemoteSessionExecutable(validating: "/opt/tools/tmux"),
            implementationVariant: "unix-tmux",
            rawVersion: "tmux 3.5a",
            semanticVersion: RemoteSessionSemanticVersion("3.5"),
            shellFamily: .posix,
            shellExecutable: "/bin/zsh"
        ))
        let request = RemoteSessionLaunchRequest(
            intent: .ensureManaged(identifier: identifier, initialCommand: nil),
            workingDirectory: "~",
            lifecycleEnvelope: deterministicRemoteSessionLifecycleEnvelope,
            transport: .ssh,
            themeStyle: deterministicRemoteSessionThemeStyle
        )

        let plan = try TmuxRemoteSessionBackend(tmux: RemoteTmuxManager())
            .launchPlan(for: request, runtime: runtime)

        #expect(plan.command.contains("'/opt/tools/tmux'"))
    }

    private func identifier(_ rawValue: String) throws -> RemoteSessionIdentifier {
        try RemoteSessionIdentifier(backendIdentifier: .zmx, validating: rawValue)
    }

    private func runtime(executablePath: String = "/opt/homebrew/bin/zmx") throws -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .zmx,
            executable: try RemoteSessionExecutable(validating: executablePath),
            implementationVariant: "zmx",
            rawVersion: "zmx 0.7.0",
            semanticVersion: RemoteSessionSemanticVersion("0.7.0"),
            shellFamily: .posix,
            shellExecutable: "/bin/zsh"
        ))
    }
}
