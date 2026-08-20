import Testing
@testable import VVTerm

struct TerminalHardwareTextInputRoutingPolicyTests {
    @Test
    func directlyRoutesLayoutResolvedLettersBeforeSystemAlternateCharacterHandling() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.directlyRoutableText(
                "h",
                primaryLanguage: "en-US",
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            ) == "h"
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.directlyRoutableText(
                "H",
                primaryLanguage: "de-DE",
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            ) == "H"
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.directlyRoutableText(
                "ż",
                primaryLanguage: "pl-PL",
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            ) == "ż"
        )
    }

    @Test
    func leavesCompositionDeadKeysAndModifiedTextWithUIKit() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.directlyRoutableText(
                "h",
                primaryLanguage: nil,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            ) == nil
        )
        for testCase in [
            ("h", "ja-JP", false, false, false, false),
            ("h", "en-US", false, false, false, true),
            ("h", "en-US", false, true, false, false),
            ("h", "en-US", false, false, true, false),
            ("h", "en-US", true, false, false, false),
            ("", "en-US", false, false, false, false),
            ("^", "de-DE", false, false, false, false),
        ] {
            #expect(
                TerminalHardwareTextInputRoutingPolicy.directlyRoutableText(
                    testCase.0,
                    primaryLanguage: testCase.1,
                    hasControlModifier: testCase.2,
                    hasAlternateModifier: testCase.3,
                    hasCommandModifier: testCase.4,
                    hasActiveIMEComposition: testCase.5
                ) == nil
            )
        }
    }

    @Test
    func koreanInputNeverAssociatesIMECommitsWithOnePhysicalKey() {
        let inputModeAllowsOneToOneText = TerminalHardwareTextInputRoutingPolicy
            .inputModeAllowsOneToOneHardwareText("ko-KR")

        #expect(!inputModeAllowsOneToOneText)
        #expect(
            TerminalHardwareTextInputRoutingPolicy.directlyRoutableText(
                "ㅎ",
                primaryLanguage: "ko-KR",
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            ) == nil
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                keyProducesText: true,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                inputModeAllowsOneToOneText: inputModeAllowsOneToOneText
            ) == false
        )
    }

    @Test
    func koreanBackwardDeleteReturnsToUIKitWhileLocalCompositionDocumentExists() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRouteBackwardDeleteToSystemTextInput(
                inputModeAllowsOneToOneText: false,
                hasLocalTextInputSession: true,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false
            )
        )
        #expect(
            !TerminalHardwareTextInputRoutingPolicy.shouldRouteBackwardDeleteToSystemTextInput(
                inputModeAllowsOneToOneText: false,
                hasLocalTextInputSession: false,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false
            )
        )
        #expect(
            !TerminalHardwareTextInputRoutingPolicy.shouldRouteBackwardDeleteToSystemTextInput(
                inputModeAllowsOneToOneText: false,
                hasLocalTextInputSession: true,
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false
            )
        )
    }

    @Test
    func repeatsPlainLayoutResolvedAndSystemInterpretedPrintableKeys() {
        for source in [
            TerminalHardwareKeyRepeatSource.layoutResolvedText,
            .systemInterpretedText,
        ] {
            #expect(
                TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                    source: source,
                    isPrintableKey: true,
                    isRepeatableSpecialKey: false,
                    hasControlModifier: false,
                    hasAlternateModifier: false,
                    hasCommandModifier: false,
                    hasActiveIMEComposition: false
                )
            )
        }
    }

    @Test
    func repeatsDirectNavigationAndDeleteKeys() {
        #expect(
            TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                source: .directTerminal,
                isPrintableKey: false,
                isRepeatableSpecialKey: true,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            )
        )
    }

    @Test
    func repeatsControlAndConfiguredOptionAsAltPrintableKeysOnDirectPath() {
        #expect(
            TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                source: .directTerminal,
                isPrintableKey: true,
                isRepeatableSpecialKey: false,
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            )
        )
        #expect(
            TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                source: .directTerminal,
                isPrintableKey: true,
                isRepeatableSpecialKey: false,
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            )
        )
    }

    @Test
    func doesNotRepeatSystemOptionTextCommandKeysOrActiveIMEInput() {
        #expect(
            !TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                source: .layoutResolvedText,
                isPrintableKey: true,
                isRepeatableSpecialKey: false,
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            )
        )
        #expect(
            !TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                source: .directTerminal,
                isPrintableKey: true,
                isRepeatableSpecialKey: false,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: true,
                hasActiveIMEComposition: false
            )
        )
        #expect(
            !TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                source: .layoutResolvedText,
                isPrintableKey: true,
                isRepeatableSpecialKey: false,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true
            )
        )
    }

    @Test
    func doesNotRepeatCapsLockOrModifierOnlyKeys() {
        #expect(
            !TerminalHardwareKeyRepeatPolicy.shouldRepeat(
                source: .directTerminal,
                isPrintableKey: false,
                isRepeatableSpecialKey: false,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false
            )
        )
    }

    @Test
    func routesPrintableHardwareTextToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesCapsLockToggleToSystemTextInputEvenThoughItIsFallbackKey() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: true,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func routesTextInputModifierOnlyKeysToSystemTextInputEvenThoughTheyAreFallbackKeys() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: true,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func routesActiveCompositionThroughSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func keepsNavigationFallbackKeysOnDirectGhosttyPathWhenNotComposing() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func keepsControlModifiedPrintableKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func routesOptionModifiedPrintableKeysToSystemTextInputForDeadKeys() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func keepsConfiguredOptionAsAltKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                usesAlternateModifierAsTerminalAlt: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func keepsConfiguredOptionModifierPressOutOfSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                usesAlternateModifierAsTerminalAlt: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: true,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            ) == false
        )
    }

    @Test
    func keepsOptionModifiedNavigationKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func keepsCommandModifiedKeysOutOfSystemTextInputPolicy() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: true,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                isTextInputModifierOnlyKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func recordsPlainPrintableHardwareKeysForInterpretedKeyEventCommit() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                keyProducesText: true,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                inputModeAllowsOneToOneText: true
            )
        )
    }

    @Test
    func doesNotRecordOptionTextAsPendingHardwareKey() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                keyProducesText: true,
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                inputModeAllowsOneToOneText: true
            ) == false
        )
    }

    @Test
    func doesNotRecordPrintableKeysDuringIMEComposition() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRecordPendingInterpretedHardwareKey(
                keyProducesText: true,
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false,
                inputModeAllowsOneToOneText: true
            ) == false
        )
    }

    @Test
    func mirrorsTextInputModifierOnlyKeysToTerminal() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldMirrorSystemTextInputModifierPressToTerminal(
                isTextInputModifierOnlyKey: true
            )
        )
    }

    @Test
    func doesNotMirrorPrintableSystemTextInputKeysToTerminal() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldMirrorSystemTextInputModifierPressToTerminal(
                isTextInputModifierOnlyKey: false
            ) == false
        )
    }

    @Test
    func consumesShiftAndAltForInterpretedTextButKeepsControlAndCommandUnconsumed() {
        let consumed = TerminalKeyInputModifierPolicy.consumedModifiers(
            for: [.shift, .alt, .ctrl, .super]
        )

        #expect(consumed.contains(.shift))
        #expect(consumed.contains(.alt))
        #expect(consumed.contains(.ctrl) == false)
        #expect(consumed.contains(.super) == false)
    }
}
