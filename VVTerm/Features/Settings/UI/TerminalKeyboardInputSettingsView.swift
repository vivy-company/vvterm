import SwiftUI

struct TerminalKeyboardInputSettingsView: View {
    var body: some View {
        TerminalKeyboardInputPlatformSettingsView()
            .accessibilityIdentifier("vvterm.settings.page.keyboardAndInput")
    }
}
