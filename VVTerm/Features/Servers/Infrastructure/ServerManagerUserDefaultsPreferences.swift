import Foundation

@MainActor
final class ServerManagerUserDefaultsPreferences: ServerManagerPreferences {
    static let didBootstrapDefaultWorkspaceKey = "com.vivy.vvterm.didBootstrapDefaultWorkspace"
    static let pendingBootstrapWorkspaceIDKey = "com.vivy.vvterm.pendingBootstrapWorkspaceID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var didBootstrapDefaultWorkspace: Bool {
        get { defaults.bool(forKey: Self.didBootstrapDefaultWorkspaceKey) }
        set { defaults.set(newValue, forKey: Self.didBootstrapDefaultWorkspaceKey) }
    }

    var hasSeenWelcome: Bool {
        defaults.bool(forKey: "hasSeenWelcome")
    }

    var freePlanGeneration: FreePlanGeneration? {
        get {
            guard let rawValue = defaults.string(forKey: FreeTierLimits.planGenerationStorageKey) else {
                return nil
            }
            return FreePlanGeneration(rawValue: rawValue)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: FreeTierLimits.planGenerationStorageKey)
            } else {
                defaults.removeObject(forKey: FreeTierLimits.planGenerationStorageKey)
            }
        }
    }

    var pendingBootstrapWorkspaceID: UUID? {
        get {
            guard let rawValue = defaults.string(
                forKey: Self.pendingBootstrapWorkspaceIDKey
            ) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            if let newValue {
                defaults.set(
                    newValue.uuidString,
                    forKey: Self.pendingBootstrapWorkspaceIDKey
                )
            } else {
                defaults.removeObject(forKey: Self.pendingBootstrapWorkspaceIDKey)
            }
        }
    }
}
