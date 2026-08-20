import SwiftUI

nonisolated enum PrivacyModeSettings {
    static let enabledKey = "security.privacyModeEnabled"
}

nonisolated enum AppContentProtectionPolicy {
    static func shouldPrepareForSceneDeactivation(
        fullAppLockEnabled: Bool,
        privacyModeEnabled: Bool,
        isAppLocked: Bool
    ) -> Bool {
        shouldObscureContent(
            sceneIsActive: false,
            fullAppLockEnabled: fullAppLockEnabled,
            privacyModeEnabled: privacyModeEnabled,
            isAppLocked: isAppLocked
        )
    }

    static func shouldObscureContent(
        sceneIsActive: Bool,
        fullAppLockEnabled: Bool,
        privacyModeEnabled: Bool,
        isAppLocked: Bool
    ) -> Bool {
        isAppLocked
            || (!sceneIsActive && (fullAppLockEnabled || privacyModeEnabled))
    }
}

nonisolated enum SensitiveContentMask {
    static let placeholder = "••••••••"

    static func value(_ value: String, privacyModeEnabled: Bool) -> String {
        privacyModeEnabled ? placeholder : value
    }
}

private struct PrivacyModeEnabledEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var privacyModeEnabled: Bool {
        get { self[PrivacyModeEnabledEnvironmentKey.self] }
        set { self[PrivacyModeEnabledEnvironmentKey.self] = newValue }
    }
}

nonisolated extension Server {
    var displayAddressWithPort: String {
        "\(username)@\(host):\(port)"
    }

    func visibleHost(privacyModeEnabled: Bool) -> String {
        SensitiveContentMask.value(host, privacyModeEnabled: privacyModeEnabled)
    }

    func visibleAddress(privacyModeEnabled: Bool) -> String {
        privacyModeEnabled ? SensitiveContentMask.placeholder : displayAddressWithPort
    }
}

nonisolated extension DiscoveredSSHHost {
    var displayEndpoint: String {
        "\(host):\(port)"
    }

    func visibleDisplayName(privacyModeEnabled: Bool) -> String {
        SensitiveContentMask.value(displayName, privacyModeEnabled: privacyModeEnabled)
    }

    func visibleEndpoint(privacyModeEnabled: Bool) -> String {
        SensitiveContentMask.value(displayEndpoint, privacyModeEnabled: privacyModeEnabled)
    }
}
