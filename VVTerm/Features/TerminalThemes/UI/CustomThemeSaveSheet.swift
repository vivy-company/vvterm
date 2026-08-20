import SwiftUI

extension TerminalThemeSelectionTarget {
    var title: String {
        switch self {
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        case .both: return String(localized: "Both")
        }
    }
}

struct CustomThemeSaveSheet: View {
    let suggestedName: String
    let usePerAppearanceTheme: Bool
    let onSave: (String, TerminalThemeSelectionTarget) throws -> Void

    @Environment(\.dismiss) var dismiss
    @State private var name: String
    @State private var applyTarget: TerminalThemeSelectionTarget = .dark
    @State private var errorMessage: String?

    init(
        suggestedName: String,
        usePerAppearanceTheme: Bool,
        onSave: @escaping (String, TerminalThemeSelectionTarget) throws -> Void
    ) {
        self.suggestedName = suggestedName
        self.usePerAppearanceTheme = usePerAppearanceTheme
        self.onSave = onSave
        _name = State(initialValue: suggestedName)
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        platformBody
    }

    var formContent: some View {
        Form {
            Section {
                platformThemeNameField(name: $name)
            } header: {
                sectionHeader("Theme Name")
            }

            if usePerAppearanceTheme {
                Section {
                    Picker("Target", selection: $applyTarget) {
                        ForEach(TerminalThemeSelectionTarget.allCases, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    sectionHeader("Apply To")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        #else
        Text(title)
        #endif
    }

    func save() {
        do {
            try onSave(
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                usePerAppearanceTheme ? applyTarget : .dark
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
