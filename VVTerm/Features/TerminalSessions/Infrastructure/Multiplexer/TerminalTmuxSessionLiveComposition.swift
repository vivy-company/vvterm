import Foundation

@MainActor
enum TerminalTmuxSessionLiveComposition {
    static func makeConfiguration(
        defaults: UserDefaults,
        serverManager: ServerManager,
        deviceID: String,
        themeStyle: @escaping @MainActor () -> RemoteTmuxThemeStyle
    ) -> TerminalTmuxConfiguration {
        TerminalTmuxConfiguration(
            deviceID: deviceID,
            enabledByDefault: {
                guard defaults.object(forKey: "terminalTmuxEnabledDefault") != nil else {
                    return true
                }
                return defaults.bool(forKey: "terminalTmuxEnabledDefault")
            },
            startupBehaviorByDefault: {
                guard let rawValue = defaults.string(
                    forKey: "terminalTmuxStartupBehaviorDefault"
                ) else {
                    return .askEveryTime
                }
                return TmuxStartupBehavior(rawValue: rawValue) ?? .askEveryTime
            },
            serverSettings: { serverId in
                serverManager.servers
                    .first(where: { $0.id == serverId })
                    .map {
                        TerminalTmuxConfiguration.ServerSettings(
                            enabledOverride: $0.tmuxEnabledOverride,
                            startupBehaviorOverride: $0.tmuxStartupBehaviorOverride
                        )
                    }
            },
            themeStyle: themeStyle
        )
    }

    nonisolated static func themeStyle(for storedName: String?) -> RemoteTmuxThemeStyle {
        let name = (try? TerminalThemeValidator.validateAndNormalizeThemeName(
            storedName ?? "Aizen Dark"
        )) ?? "Aizen Dark"
        return RemoteTmuxThemeStyle(
            name: name,
            modeStyle: ThemeColorParser.tmuxModeStyle(for: name)
        )
    }
}

extension RemoteTmuxManager: TerminalRemoteTmuxServicing {}
