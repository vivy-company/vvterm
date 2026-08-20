#if os(iOS)
import SwiftUI

struct TerminalSessionPlatformSettingsSection: View {
    var body: some View {
        Section("Terminal Session") {
            TerminalScreenAwakeSettingRow()
        }
    }
}

struct TerminalScreenAwakeSettingRow: View {
    @AppStorage(TerminalDefaults.keepScreenAwakeKey)
    private var keepScreenAwake = TerminalDefaults.defaultKeepScreenAwake

    var body: some View {
        Toggle("Keep screen awake", isOn: $keepScreenAwake)
            .accessibilityIdentifier("vvterm.settings.terminal.keepScreenAwake")
    }
}
#endif
