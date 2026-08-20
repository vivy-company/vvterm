import Foundation
import os
import Testing
@testable import VVTerm

struct SSHStartupTraceTests {
    @Test
    func recordsMonotonicStructuredStageEvents() {
        let events = OSAllocatedUnfairLock(initialState: [SSHStartupTrace.Event]())
        let trace = SSHStartupTrace(logger: Logger()) { event in
            events.withLock { $0.append(event) }
        }

        let token = trace.begin(.dnsResolution)
        trace.end(token, detail: "candidates_2")
        trace.recordOnce(.firstTerminalByte, detail: "ssh")
        trace.recordOnce(.firstTerminalByte, detail: "ssh")

        let recorded = events.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded.map(\.stage) == [.dnsResolution, .firstTerminalByte])
        #expect(recorded.allSatisfy { $0.stageMilliseconds >= 0 })
        #expect(recorded[1].totalMilliseconds >= recorded[0].totalMilliseconds)
        #expect(recorded[0].detail == "candidates_2")
        #expect(trace.snapshot() == recorded)
    }

    @Test
    func moshFallbackDiagnosticsAllowlistTraceDetailsAndMapFailureStage() {
        let events = [
            SSHStartupTrace.Event(
                stage: .moshBootstrap,
                stageMilliseconds: 120,
                totalMilliseconds: 120,
                outcome: "ok",
                detail: RemoteMoshManager.PortClass.standardMoshRange.rawValue
            ),
            SSHStartupTrace.Event(
                stage: .moshEndpoint,
                stageMilliseconds: 0,
                totalMilliseconds: 121,
                outcome: "selected",
                detail: "configured"
            ),
            SSHStartupTrace.Event(
                stage: .moshUDPSession,
                stageMilliseconds: 8_000,
                totalMilliseconds: 8_121,
                outcome: "failed",
                detail: "secret.example.com MOSH_KEY=hunter2"
            ),
            SSHStartupTrace.Event(
                stage: .sshFallback,
                stageMilliseconds: 42,
                totalMilliseconds: 8_163,
                outcome: "ok",
                detail: "udpTimeout"
            ),
        ]

        let diagnostics = MoshFallbackDiagnostics.make(
            reason: .udpTimeout,
            events: events,
            appContext: .init(version: "2.6 (100)", platform: "iOS test")
        )

        #expect(diagnostics.failureStage == .moshUDPSession)
        #expect(diagnostics.endpointClass == "configured")
        #expect(diagnostics.portClass == "standardMoshRange")
        #expect(diagnostics.stageDurations.map(\.milliseconds) == [120, 0, 8_000, 42])
        #expect(diagnostics.copyText.contains("selected_transport=mosh"))
        #expect(diagnostics.copyText.contains("actual_transport=sshFallback"))
        #expect(diagnostics.copyText.contains("fallback_result=connected"))
        #expect(!diagnostics.copyText.contains("secret.example.com"))
        #expect(!diagnostics.copyText.contains("MOSH_KEY"))
        #expect(!diagnostics.copyText.contains("hunter2"))
    }

    @Test
    func moshFallbackDiagnosticsRejectUnknownEndpointAndPortDetails() {
        let diagnostics = MoshFallbackDiagnostics.make(
            reason: .bootstrapFailed,
            events: [
                .init(
                    stage: .moshBootstrap,
                    stageMilliseconds: -1,
                    totalMilliseconds: 1,
                    outcome: "failed",
                    detail: "60001 key=private"
                ),
                .init(
                    stage: .moshEndpoint,
                    stageMilliseconds: 0,
                    totalMilliseconds: 1,
                    outcome: "failed",
                    detail: "192.0.2.1"
                ),
            ],
            appContext: .init(version: "test", platform: "test")
        )

        #expect(diagnostics.portClass == "unavailable")
        #expect(diagnostics.endpointClass == "unavailable")
        #expect(diagnostics.failureStage == .moshBootstrap)
        #expect(diagnostics.stageDurations.first?.milliseconds == 0)
        #expect(!diagnostics.copyText.contains("60001"))
        #expect(!diagnostics.copyText.contains("192.0.2.1"))
        #expect(!diagnostics.copyText.contains("private"))
    }
}
