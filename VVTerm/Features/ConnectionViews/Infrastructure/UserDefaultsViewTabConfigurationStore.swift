import Foundation
import os.log

@MainActor
final class UserDefaultsViewTabConfigurationStore: ConnectionViewTabConfigurationPersisting {
    static let configurationKey = "connectionViewTabConfiguration"

    private enum LegacyKey {
        static let order = "connectionViewTabOrder"
        static let defaultTab = "connectionDefaultViewTab"
        static let showStats = "showStatsTab"
        static let showTerminal = "showTerminalTab"
        static let showFiles = "showFilesTab"

        static let all = [order, defaultTab, showStats, showTerminal, showFiles]
    }

    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivy.vvterm",
        category: "ViewTabConfigurationManager"
    )

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> ConnectionViewTabConfiguration {
        if let data = defaults.data(forKey: Self.configurationKey) {
            do {
                let configuration = try JSONDecoder().decode(
                    ConnectionViewTabConfiguration.self,
                    from: data
                )
                removeLegacyConfiguration()
                return configuration
            } catch {
                logger.error("Failed to decode view tab configuration: \(error.localizedDescription)")
            }
        }

        guard LegacyKey.all.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return .default
        }

        let configuration = migratedLegacyConfiguration()
        if saveConfiguration(configuration) {
            removeLegacyConfiguration()
        }
        return configuration
    }

    func save(_ configuration: ConnectionViewTabConfiguration) {
        _ = saveConfiguration(configuration)
    }

    private func migratedLegacyConfiguration() -> ConnectionViewTabConfiguration {
        let order: [ConnectionViewTabID]
        if let data = defaults.data(forKey: LegacyKey.order),
           let storedOrder = try? JSONDecoder().decode([String].self, from: data) {
            order = storedOrder.compactMap(ConnectionViewTabID.init(rawValue:))
        } else {
            order = ConnectionViewTabID.allCases
        }

        let defaultTab = defaults.string(forKey: LegacyKey.defaultTab)
            .flatMap(ConnectionViewTabID.init(rawValue:))
            ?? .stats

        let visibleTabs = Set(ConnectionViewTabID.allCases.filter { tab in
            let key = switch tab {
            case .stats: LegacyKey.showStats
            case .terminal: LegacyKey.showTerminal
            case .files: LegacyKey.showFiles
            }
            return defaults.object(forKey: key) as? Bool ?? true
        })

        return ConnectionViewTabConfiguration(
            order: order,
            visibleTabs: visibleTabs,
            defaultTab: defaultTab
        )
    }

    private func saveConfiguration(_ configuration: ConnectionViewTabConfiguration) -> Bool {
        do {
            defaults.set(
                try JSONEncoder().encode(configuration),
                forKey: Self.configurationKey
            )
            return true
        } catch {
            logger.error("Failed to encode view tab configuration: \(error.localizedDescription)")
            return false
        }
    }

    private func removeLegacyConfiguration() {
        LegacyKey.all.forEach(defaults.removeObject(forKey:))
    }
}

extension ViewTabConfigurationManager {
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            persistence: UserDefaultsViewTabConfigurationStore(defaults: defaults)
        )
    }
}
