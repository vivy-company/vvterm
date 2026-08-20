import Foundation

nonisolated enum SettingsRoutePersistence {
    static let selectedRouteKey = "settings.selectedRoute"

    static func load(from defaults: UserDefaults) -> SettingsRoute {
        guard let rawValue = defaults.string(forKey: selectedRouteKey),
              let route = SettingsRoute(rawValue: rawValue) else {
            return .defaultRoute
        }
        return route
    }

    static func save(_ route: SettingsRoute, to defaults: UserDefaults) {
        defaults.set(route.rawValue, forKey: selectedRouteKey)
    }

    static func route(for rawValue: String) -> SettingsRoute {
        SettingsRoute(rawValue: rawValue) ?? .defaultRoute
    }
}
