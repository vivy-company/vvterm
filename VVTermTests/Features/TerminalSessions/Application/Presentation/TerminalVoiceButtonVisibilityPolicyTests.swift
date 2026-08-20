import Testing
@testable import VVTerm

struct TerminalVoiceButtonVisibilityPolicyTests {
    @Test
    func focusedSelectedPaneShowsEnabledVoiceButton() {
        #expect(
            TerminalVoiceButtonVisibilityPolicy.isVisible(
                settingEnabled: true,
                tabSelected: true,
                paneFocused: true,
                recording: false
            )
        )
    }

    @Test
    func unavailableVoiceButtonStateIsHidden() {
        let cases = [
            (settingEnabled: false, tabSelected: true, paneFocused: true, recording: false),
            (settingEnabled: true, tabSelected: false, paneFocused: true, recording: false),
            (settingEnabled: true, tabSelected: true, paneFocused: false, recording: false),
            (settingEnabled: true, tabSelected: true, paneFocused: true, recording: true),
        ]

        for testCase in cases {
            #expect(
                !TerminalVoiceButtonVisibilityPolicy.isVisible(
                    settingEnabled: testCase.settingEnabled,
                    tabSelected: testCase.tabSelected,
                    paneFocused: testCase.paneFocused,
                    recording: testCase.recording
                )
            )
        }
    }
}
