import SwiftUI

struct TerminalSessionsConnectionsSettingsView: View {
    @AppStorage("terminalTmuxEnabledDefault") private var tmuxEnabledDefault = true
    @AppStorage("terminalTmuxStartupBehaviorDefault") private var tmuxStartupBehaviorRaw = TmuxStartupBehavior.askEveryTime.rawValue
    @AppStorage(SSHRuntimeSettings.keepAliveEnabledKey) private var keepAliveEnabled = true
    @AppStorage(SSHRuntimeSettings.keepAliveIntervalKey) private var keepAliveInterval = 30
    @AppStorage(TerminalDefaults.sshAutoReconnectKey) private var autoReconnect = true

    private var tmuxStartupBehaviorBinding: Binding<TmuxStartupBehavior> {
        Binding(
            get: { TmuxStartupBehavior(rawValue: tmuxStartupBehaviorRaw) ?? .askEveryTime },
            set: { tmuxStartupBehaviorRaw = $0.rawValue }
        )
    }

    private var tmuxStartupBehavior: TmuxStartupBehavior {
        TmuxStartupBehavior(rawValue: tmuxStartupBehaviorRaw) ?? .askEveryTime
    }

    var body: some View {
        Form {
            TerminalSessionPlatformSettingsSection()

            Section {
                Toggle("Enable tmux by default", isOn: $tmuxEnabledDefault)

                if tmuxEnabledDefault {
                    Picker("On connect", selection: tmuxStartupBehaviorBinding) {
                        ForEach(TmuxStartupBehavior.configCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }

                    Text(tmuxStartupBehavior.descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Session Persistence")
            } footer: {
                Text("Choose the default behavior for new servers. You can still override per server in server settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH Connection") {
                Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
                Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)

                if keepAliveEnabled {
                    Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
                }
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.sessionsAndConnections")
    }
}
