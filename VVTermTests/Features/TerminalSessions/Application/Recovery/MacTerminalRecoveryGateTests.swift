#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

struct MacTerminalRecoveryGateTests {
    @Test
    func wakeSignalsCoalesceIntoOneRecoveryGeneration() {
        var gate = MacTerminalRecoveryGate()

        #expect(gate.receive(.sleep, networkReadiness: .ready) == .none)
        #expect(gate.receive(.sleep, networkReadiness: .ready) == .none)

        guard case .recover = gate.receive(.wake, networkReadiness: .ready) else {
            Issue.record("Expected one wake recovery")
            return
        }
        #expect(gate.receive(.wake, networkReadiness: .ready) == .none)
        #expect(gate.receive(.applicationActivated, networkReadiness: .ready) == .none)
        #expect(gate.receive(.networkChanged(.ready), networkReadiness: .ready) == .none)
    }

    @Test
    func offlineWakeWaitsUntilOneReadyTransition() {
        var gate = MacTerminalRecoveryGate()

        #expect(gate.receive(.sleep, networkReadiness: .unavailable) == .none)
        guard case .waitForNetwork(let waitingGeneration) = gate.receive(
            .wake,
            networkReadiness: .unavailable
        ) else {
            Issue.record("Expected an offline waiting generation")
            return
        }

        #expect(gate.receive(.wake, networkReadiness: .unavailable) == .none)
        #expect(gate.receive(.networkChanged(.unavailable), networkReadiness: .unavailable) == .none)
        #expect(
            gate.receive(.networkChanged(.ready), networkReadiness: .ready)
                == .recover(waitingGeneration)
        )
        #expect(gate.receive(.networkChanged(.ready), networkReadiness: .ready) == .none)
    }

    @Test
    func networkDropDuringRecoveryReturnsTheSameGenerationToWaiting() {
        var gate = MacTerminalRecoveryGate()

        #expect(gate.receive(.sleep, networkReadiness: .ready) == .none)
        guard case .recover(let generation) = gate.receive(
            .wake,
            networkReadiness: .ready
        ) else {
            Issue.record("Expected recovery to start")
            return
        }

        #expect(
            gate.receive(.networkChanged(.unavailable), networkReadiness: .unavailable)
                == .waitForNetwork(generation)
        )
        #expect(
            gate.receive(.networkChanged(.ready), networkReadiness: .ready)
                == .recover(generation)
        )
        gate.complete(generation)
        #expect(gate.receive(.networkChanged(.ready), networkReadiness: .ready) == .none)
    }
}

@MainActor
struct MacTerminalRecoveryPolicyTests {
    @Test(arguments: [
        (ConnectionState.connecting, false, true),
        (.reconnecting(attempt: 1), true, true),
        (.disconnected, true, true),
        (.failed(terminalExternalFailure("stale")), true, true),
        (.connected, true, false),
        (.idle, true, false),
        (.disconnected, false, false),
        (.failed(terminalExternalFailure("initial")), false, false),
    ])
    func offlinePreparationCoversRecoverableStates(
        connectionState: ConnectionState,
        hasEstablishedConnection: Bool,
        expected: Bool
    ) {
        #expect(
            MacTerminalRecoveryPolicy.shouldPrepareWhileOffline(
                connectionState: connectionState,
                hasEstablishedConnection: hasEstablishedConnection
            ) == expected
        )
    }

    @Test
    func eternalTerminalStatesGetOneBoundedSelfRecoveryWindow() {
        for state in [
            ConnectionState.connected,
            .reconnecting(attempt: 1),
            .failed(terminalExternalFailure("unrecoverable")),
        ] {
            #expect(
                MacTerminalRecoveryPolicy.readyStrategy(
                    connectionState: state,
                    hasEstablishedConnection: true,
                    activeTransport: .eternalTerminal,
                    hasEternalTerminalRuntime: true
                ) == .allowEternalTerminalSelfRecovery
            )
        }
        #expect(
            MacTerminalRecoveryPolicy.readyStrategy(
                connectionState: .connected,
                hasEstablishedConnection: true,
                activeTransport: .eternalTerminal,
                hasEternalTerminalRuntime: false
            ) == .verifyOrReplace
        )
    }

    @Test
    func moshAndStandardSSHUseLiveVerificationBeforeReplacement() {
        for transport in [ShellTransport.ssh, .sshFallback, .mosh] {
            #expect(
                MacTerminalRecoveryPolicy.readyStrategy(
                    connectionState: .reconnecting(attempt: 1),
                    hasEstablishedConnection: true,
                    activeTransport: transport,
                    hasEternalTerminalRuntime: false
                ) == .verifyOrReplace
            )
        }
    }

    @Test
    func liveTransportVerificationPreservesOnlyOwnedUsableSessions() {
        #expect(
            MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: .connected,
                activeTransport: .ssh,
                hasEternalTerminalRuntime: false,
                hasShellOwnership: true,
                transportIsLive: true
            )
        )
        #expect(
            !MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: .reconnecting(attempt: 1),
                activeTransport: .ssh,
                hasEternalTerminalRuntime: false,
                hasShellOwnership: true,
                transportIsLive: true
            )
        )
        #expect(
            MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: .reconnecting(attempt: 1),
                activeTransport: .mosh,
                hasEternalTerminalRuntime: false,
                hasShellOwnership: true,
                transportIsLive: true
            )
        )
        #expect(
            MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: .connected,
                activeTransport: .eternalTerminal,
                hasEternalTerminalRuntime: true,
                hasShellOwnership: false,
                transportIsLive: true
            )
        )
        #expect(
            !MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: .reconnecting(attempt: 1),
                activeTransport: .eternalTerminal,
                hasEternalTerminalRuntime: true,
                hasShellOwnership: false,
                transportIsLive: true
            )
        )
        #expect(
            !MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: .connected,
                activeTransport: .eternalTerminal,
                hasEternalTerminalRuntime: true,
                hasShellOwnership: false,
                transportIsLive: false
            )
        )
        #expect(
            !MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: .failed(terminalExternalFailure("stale")),
                activeTransport: .mosh,
                hasEternalTerminalRuntime: false,
                hasShellOwnership: true,
                transportIsLive: true
            )
        )
    }
}
#endif
