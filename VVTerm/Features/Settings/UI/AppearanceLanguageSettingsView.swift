import SwiftUI

struct AppearanceLanguageSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName)
                            .tag(language.rawValue)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Some changes may require restarting the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                AppearancePickerView(selection: $appearanceMode)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.appearanceAndLanguage")
        .onChange(of: appLanguage) { newValue in
            AppLanguage.applySelection(newValue)
        }
    }
}
