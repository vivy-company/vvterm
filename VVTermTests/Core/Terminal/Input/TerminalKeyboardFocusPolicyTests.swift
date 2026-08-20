import Testing
@testable import VVTerm

struct TerminalKeyboardFocusPolicyTests {
    @Test
    func userDismissEntersBrowseModeUntilExplicitShow() {
        var policy = TerminalKeyboardFocusPolicy()

        let initialActivationAccepted = policy.requestFocus(for: .initialActivation)
        #expect(initialActivationAccepted)
        #expect(policy.allowsAutomaticFocus)
        #expect(!policy.isBrowsing)
        #expect(policy.shouldRestoreOnReconnect)

        policy.dismissForUser()
        #expect(!policy.allowsAutomaticFocus)
        #expect(policy.isBrowsing)
        #expect(!policy.shouldRestoreOnReconnect)

        let automaticActivationAccepted = policy.requestFocus(for: .initialActivation)
        let directTouchAccepted = policy.requestFocus(for: .directTouch)
        let selectionGestureAccepted = policy.requestFocus(for: .selectionGesture)
        let reconnectRestoreAccepted = policy.requestFocus(for: .reconnectRestore)
        #expect(!automaticActivationAccepted)
        #expect(!directTouchAccepted)
        #expect(!selectionGestureAccepted)
        #expect(!reconnectRestoreAccepted)
        #expect(policy.isBrowsing)

        let explicitRequestAccepted = policy.requestFocus(for: .explicitUserRequest)
        #expect(explicitRequestAccepted)
        #expect(policy.allowsAutomaticFocus)
        #expect(!policy.isBrowsing)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func explicitShowLeavesBrowseMode() {
        var policy = TerminalKeyboardFocusPolicy()

        policy.dismissForUser()
        #expect(policy.isBrowsing)

        let requestAccepted = policy.requestFocus(for: .explicitUserRequest)
        #expect(requestAccepted)
        #expect(policy.allowsAutomaticFocus)
        #expect(!policy.isBrowsing)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func hardwareFocusDoesNotLeaveBrowseModeAfterUserDismiss() {
        var policy = TerminalKeyboardFocusPolicy()

        policy.dismissForUser()

        let requestAccepted = policy.requestFocus(for: .hardwareKeyboard)
        #expect(!requestAccepted)
        #expect(!policy.allowsAutomaticFocus)
        #expect(policy.isBrowsing)
        #expect(!policy.shouldRestoreOnReconnect)
    }

    @Test
    func reconnectRestoreRequiresPriorTypingIntent() {
        var policy = TerminalKeyboardFocusPolicy()

        let reconnectBeforeTyping = policy.requestFocus(for: .reconnectRestore)
        #expect(!reconnectBeforeTyping)

        let explicitRequestAccepted = policy.requestFocus(for: .explicitUserRequest)
        let reconnectAfterTyping = policy.requestFocus(for: .reconnectRestore)
        #expect(explicitRequestAccepted)
        #expect(reconnectAfterTyping)

        policy.dismissForUser()
        let reconnectAfterDismiss = policy.requestFocus(for: .reconnectRestore)
        #expect(!reconnectAfterDismiss)
    }

    @Test
    func explicitKeyboardRequestOverridesHardwareSuppressionUntilDismissed() {
        var policy = TerminalKeyboardFocusPolicy()

        #expect(policy.shouldSuppressSoftwareKeyboard(hasHardwareKeyboardAttached: true))
        #expect(!policy.forcesSoftwareKeyboardPresentation)

        let explicitRequestAccepted = policy.requestFocus(for: .explicitUserRequest)
        #expect(explicitRequestAccepted)
        #expect(policy.forcesSoftwareKeyboardPresentation)
        #expect(!policy.shouldSuppressSoftwareKeyboard(hasHardwareKeyboardAttached: true))

        for reason in [
            TerminalKeyboardFocusReason.hardwareKeyboard,
            .initialActivation,
            .directTouch,
            .selectionGesture,
            .reconnectRestore,
        ] {
            let requestAccepted = policy.requestFocus(for: reason)
            #expect(requestAccepted)
            #expect(policy.forcesSoftwareKeyboardPresentation)
            #expect(!policy.shouldSuppressSoftwareKeyboard(hasHardwareKeyboardAttached: true))
        }

        policy.dismissForUser()

        #expect(!policy.forcesSoftwareKeyboardPresentation)
        #expect(policy.shouldSuppressSoftwareKeyboard(hasHardwareKeyboardAttached: true))
        let hardwareFocusAccepted = policy.requestFocus(for: .hardwareKeyboard)
        #expect(!hardwareFocusAccepted)
    }
}
