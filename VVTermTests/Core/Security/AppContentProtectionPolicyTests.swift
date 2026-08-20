import Testing
@testable import VVTerm

struct AppContentProtectionPolicyTests {
    @Test(arguments: [
        (sceneIsActive: false, fullAppLockEnabled: false, privacyModeEnabled: true, isAppLocked: false),
        (sceneIsActive: false, fullAppLockEnabled: true, privacyModeEnabled: false, isAppLocked: false),
        (sceneIsActive: true, fullAppLockEnabled: true, privacyModeEnabled: false, isAppLocked: true),
    ])
    func protectedStateObscuresContent(
        sceneIsActive: Bool,
        fullAppLockEnabled: Bool,
        privacyModeEnabled: Bool,
        isAppLocked: Bool
    ) {
        #expect(
            AppContentProtectionPolicy.shouldObscureContent(
                sceneIsActive: sceneIsActive,
                fullAppLockEnabled: fullAppLockEnabled,
                privacyModeEnabled: privacyModeEnabled,
                isAppLocked: isAppLocked
            )
        )
    }

    @Test
    func activeUnlockedAppDoesNotObscureContent() {
        #expect(
            !AppContentProtectionPolicy.shouldObscureContent(
                sceneIsActive: true,
                fullAppLockEnabled: true,
                privacyModeEnabled: true,
                isAppLocked: false
            )
        )
    }

    @Test(arguments: [
        (fullAppLockEnabled: false, privacyModeEnabled: true, isAppLocked: false),
        (fullAppLockEnabled: true, privacyModeEnabled: false, isAppLocked: false),
        (fullAppLockEnabled: false, privacyModeEnabled: false, isAppLocked: true),
    ])
    func protectedAppPreparesBeforeSceneDeactivation(
        fullAppLockEnabled: Bool,
        privacyModeEnabled: Bool,
        isAppLocked: Bool
    ) {
        #expect(
            AppContentProtectionPolicy.shouldPrepareForSceneDeactivation(
                fullAppLockEnabled: fullAppLockEnabled,
                privacyModeEnabled: privacyModeEnabled,
                isAppLocked: isAppLocked
            )
        )
    }

    @Test
    func unprotectedAppPreservesInputDuringSceneDeactivation() {
        #expect(
            !AppContentProtectionPolicy.shouldPrepareForSceneDeactivation(
                fullAppLockEnabled: false,
                privacyModeEnabled: false,
                isAppLocked: false
            )
        )
    }

    @Test
    func privacyModeMasksDiscoveredHostText() {
        let host = DiscoveredSSHHost(
            displayName: "Secret server",
            host: "private.example.com",
            port: 2222,
            sources: [.bonjour]
        )

        #expect(host.visibleDisplayName(privacyModeEnabled: true) == SensitiveContentMask.placeholder)
        #expect(host.visibleEndpoint(privacyModeEnabled: true) == SensitiveContentMask.placeholder)
        #expect(host.visibleDisplayName(privacyModeEnabled: false) == "Secret server")
        #expect(host.visibleEndpoint(privacyModeEnabled: false) == "private.example.com:2222")
    }
}
