import Foundation
import Testing
@testable import VVTerm

@MainActor
struct SSHRuntimeSettingsTests {
    @Test
    func missingValuesUseEnabledThirtySecondDefault() {
        withDefaults { defaults in
            #expect(
                SSHRuntimeSettings(defaults: defaults).keepAlive
                    == .enabled(intervalSeconds: 30)
            )
        }
    }

    @Test
    func disabledSettingReachesRuntimePolicy() {
        withDefaults { defaults in
            defaults.set(false, forKey: SSHRuntimeSettings.keepAliveEnabledKey)
            defaults.set(90, forKey: SSHRuntimeSettings.keepAliveIntervalKey)

            #expect(SSHRuntimeSettings(defaults: defaults).keepAlive == .disabled)
        }
    }

    @Test
    func invalidStoredTypesUseDefaults() {
        withDefaults { defaults in
            defaults.set("invalid", forKey: SSHRuntimeSettings.keepAliveEnabledKey)
            defaults.set("invalid", forKey: SSHRuntimeSettings.keepAliveIntervalKey)

            #expect(
                SSHRuntimeSettings(defaults: defaults).keepAlive
                    == .enabled(intervalSeconds: 30)
            )
        }
    }

    @Test(arguments: [0, 9, 10, 70, 120, 121, Int.max])
    func intervalIsBoundedBeforeRuntimeUse(stored: Int) {
        withDefaults { defaults in
            defaults.set(true, forKey: SSHRuntimeSettings.keepAliveEnabledKey)
            defaults.set(stored, forKey: SSHRuntimeSettings.keepAliveIntervalKey)

            let expected = min(max(stored, 10), 120)
            #expect(
                SSHRuntimeSettings(defaults: defaults).keepAlive
                    == .enabled(intervalSeconds: expected)
            )
        }
    }

    @Test
    func sessionConfigurationReceivesTypedRuntimePolicy() {
        let credentials = ServerCredentials(
            serverId: UUID(),
            credentialBinding: nil,
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )
        let config = SSHSessionConfig(
            host: "example.com",
            port: 22,
            username: "test",
            connectionMode: .standard,
            authMethod: .password,
            credentials: credentials,
            keepAlive: SSHKeepAlivePolicy.enabled(intervalSeconds: 45)
        )

        #expect(config.keepAlive == .enabled(intervalSeconds: 45))
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "SSHRuntimeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
