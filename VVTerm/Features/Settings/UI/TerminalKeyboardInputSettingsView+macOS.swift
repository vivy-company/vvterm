#if os(macOS)
import SwiftUI

struct TerminalKeyboardInputPlatformSettingsView: View {
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var optionAsAltModeRaw = TerminalOptionAsAltMode.none.rawValue

    private var optionAsAltModeBinding: Binding<TerminalOptionAsAltMode> {
        Binding(
            get: { TerminalOptionAsAltMode(rawValue: optionAsAltModeRaw) ?? .none },
            set: { optionAsAltModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Option as Alt", selection: optionAsAltModeBinding) {
                    ForEach(TerminalOptionAsAltMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Hardware Keyboard")
            } footer: {
                Text("Choose which Option key sends Alt. The other key still types layout characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
    }
}
#endif
