import Foundation

@MainActor
extension EternalTerminalRuntimeDependencies {
    static func live(
        resumeStore: any EternalTerminalResumeStoring,
        analyticsTracker: AnalyticsTracker,
        remoteTmux: any TerminalRemoteTmuxServicing,
        sshClientFactory: SSHClientFactory
    ) -> Self {
        Self(
            recordEvent: { event in
                switch event {
                case .connectionAttempted:
                    analyticsTracker.trackConnectionAttempted(
                        transport: ShellTransport.eternalTerminal.rawValue
                    )
                case .connectionReconnecting:
                    analyticsTracker.trackConnectionReconnecting(
                        transport: ShellTransport.eternalTerminal.rawValue
                    )
                case .connectionFailed(let reason):
                    analyticsTracker.trackConnectionFailed(
                        transport: ShellTransport.eternalTerminal.rawValue,
                        reason: reason
                    )
                }
            },
            tmuxSessionKiller: LiveEternalTerminalTmuxSessionKiller(
                remoteTmux: remoteTmux
            ),
            sessionPreparer: LiveEternalTerminalSessionPreparer(
                resumeStore: resumeStore,
                sshClientFactory: sshClientFactory
            )
        )
    }
}

private nonisolated struct LiveEternalTerminalTmuxSessionKiller: EternalTerminalTmuxSessionKilling {
    let remoteTmux: any TerminalRemoteTmuxServicing

    func killSession(named sessionName: String, using client: SSHClient) async {
        await remoteTmux.killSession(
            named: sessionName,
            using: client,
            backend: nil
        )
    }
}
