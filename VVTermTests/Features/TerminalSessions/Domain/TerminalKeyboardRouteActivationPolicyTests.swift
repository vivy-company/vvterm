#if os(iOS)
import Testing
@testable import VVTerm

struct TerminalKeyboardRouteActivationPolicyTests {
    @Test(arguments: [false, true])
    func temporarySystemOverlayPreservesKeyboardIntent(userHidKeyboard: Bool) {
        let effects = [
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundActive
            ),
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundInactive
            ),
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundActive
            ),
        ]

        #expect(effects == [.activate, .suspend, .activate])

        let restoredInputs = TerminalKeyboardCoordinator.StateInputs(
            viewActive: true,
            activePaneInputEligible: true,
            activePaneWindowAttached: true,
            allowsLocalInputOwnership: true,
            userHidKeyboard: userHidKeyboard,
            findNavigatorActive: false
        )
        #expect(TerminalKeyboardCoordinator.desiredInputSessionActive(inputs: restoredInputs))
        #expect(
            TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: restoredInputs)
                == !userHidKeyboard
        )
    }

    @Test(arguments: [false, true])
    func routeModalReleasesInputAndRestoresPriorKeyboardIntent(userHidKeyboard: Bool) {
        let effects = [
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundActive,
                windowOwnership: .key,
                presentationOwnership: .routeModal
            ),
            TerminalKeyboardRouteActivationPolicy.effect(
                routeVisible: true,
                terminalSelected: true,
                sceneActivation: .foregroundActive,
                windowOwnership: .key,
                presentationOwnership: .terminal
            ),
        ]

        #expect(effects == [.deactivate, .activate])

        let restoredInputs = TerminalKeyboardCoordinator.StateInputs(
            viewActive: true,
            activePaneInputEligible: true,
            activePaneWindowAttached: true,
            allowsLocalInputOwnership: true,
            userHidKeyboard: userHidKeyboard,
            findNavigatorActive: false
        )
        #expect(TerminalKeyboardCoordinator.desiredInputSessionActive(inputs: restoredInputs))
        #expect(
            TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: restoredInputs)
                == !userHidKeyboard
        )
    }

    @Test
    func realBackgroundSuspendsNativeInputOwnership() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .background
        )

        #expect(effect == .suspend)
    }

    @Test
    func leavingTerminalDeactivatesEvenDuringTemporaryOverlay() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: false,
            terminalSelected: true,
            sceneActivation: .foregroundInactive
        )

        #expect(effect == .deactivate)
    }

    @Test
    func privacyShieldDeactivatesInputDuringTemporarySceneInactivity() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .foregroundInactive,
            contentObscured: true
        )

        #expect(effect == .deactivate)
    }

    @Test
    func crossAppFocusTransferSuspendsNativeInputOwnership() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .foregroundInactive,
            windowOwnership: .notKey
        )

        #expect(effect == .suspend)
    }

    @Test
    func temporarySystemOverlaySuspendsResponderWhilePreservingIntent() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .foregroundInactive,
            windowOwnership: .key
        )

        #expect(effect == .suspend)
    }

    @Test
    func foregroundRouteCannotAcquireInputBeforeItsWindowBecomesKey() {
        let effect = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .foregroundActive,
            windowOwnership: .notKey
        )

        #expect(effect == .deactivate)
    }

    @Test
    func biometricUnlockTransitionsFromPreservedToActiveRoute() {
        let unlockWhileFaceIDIsDismissing = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .foregroundInactive,
            windowOwnership: .key,
            contentObscured: false
        )

        #expect(unlockWhileFaceIDIsDismissing == .suspend)

        let fullyActive = TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: true,
            sceneActivation: .foregroundActive,
            windowOwnership: .key,
            contentObscured: false
        )

        #expect(fullyActive == .activate)
    }
}
#endif
