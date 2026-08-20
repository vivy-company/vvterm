import SwiftUI

struct TerminalThemeSettingsSection: View {
    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager

    @State private var customThemeErrorMessage: String?
    #if os(macOS)
    @State private var showingCustomThemeManager = false
    #endif

    private var builtInThemeOptions: [String] {
        Set(terminalThemeManager.builtInThemeNames)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var customThemes: [TerminalTheme] {
        terminalThemeManager.customThemes
            .filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var customThemeOptions: [String] {
        let builtIn = Set(builtInThemeOptions)
        return customThemes.filter(\.canApply).map(\.name).filter { !builtIn.contains($0) }
    }

    private var allThemeNames: [String] {
        builtInThemeOptions + customThemeOptions
    }

    private var themeSelection: TerminalThemeSelection {
        terminalThemeManager.themeSelection
    }

    private var darkThemeNameBinding: Binding<String> {
        Binding(
            get: { terminalThemeManager.themeSelection.darkThemeName },
            set: { terminalThemeManager.selectTheme(named: $0, for: .dark) }
        )
    }

    private var lightThemeNameBinding: Binding<String> {
        Binding(
            get: { terminalThemeManager.themeSelection.lightThemeName },
            set: { terminalThemeManager.selectTheme(named: $0, for: .light) }
        )
    }

    private var usePerAppearanceThemeBinding: Binding<Bool> {
        Binding(
            get: { terminalThemeManager.themeSelection.usePerAppearanceTheme },
            set: { terminalThemeManager.setUsesPerAppearanceTheme($0) }
        )
    }

    private var customThemeErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { customThemeErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    customThemeErrorMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var themePickerRows: some View {
        if !builtInThemeOptions.isEmpty {
            Section("Built-in") {
                ForEach(builtInThemeOptions, id: \.self) { theme in
                    Text(theme).tag(theme)
                }
            }
        }

        if !customThemeOptions.isEmpty {
            Section("Custom") {
                ForEach(customThemeOptions, id: \.self) { theme in
                    Text(theme).tag(theme)
                }
            }
        }
    }

    var body: some View {
        Section("Theme") {
            Toggle(
                "Separate Light and Dark Themes",
                isOn: usePerAppearanceThemeBinding
            )

            if themeSelection.usePerAppearanceTheme {
                Picker("Dark Theme", selection: darkThemeNameBinding) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)

                Picker("Light Theme", selection: lightThemeNameBinding) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)
            } else {
                Picker("Theme", selection: darkThemeNameBinding) {
                    themePickerRows
                }
                .disabled(allThemeNames.isEmpty)
            }

            customThemesControl
        }
        #if os(macOS)
        .sheet(isPresented: $showingCustomThemeManager) {
            customThemesManager {
                showingCustomThemeManager = false
            }
            .adaptiveSoftScrollEdges()
        }
        #endif
        .alert("Custom Theme", isPresented: customThemeErrorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(customThemeErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var customThemesControl: some View {
        #if os(iOS)
        NavigationLink {
            customThemesManager(onClose: {})
        } label: {
            customThemesLabel
        }
        .accessibilityIdentifier("vvterm.settings.appearance.customThemes")
        #else
        Button {
            showingCustomThemeManager = true
        } label: {
            customThemesLabel
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vvterm.settings.appearance.customThemes")
        #endif
    }

    private var customThemesLabel: some View {
        HStack(spacing: 10) {
            Text("Custom Themes")

            Spacer(minLength: 8)

            Text(customThemes.count, format: .number)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func customThemesManager(onClose: @escaping () -> Void) -> some View {
        ManageCustomThemesSheet(
            customThemes: customThemes,
            themeSelection: themeSelection,
            onClose: onClose,
            onSuggestThemeName: { source in
                terminalThemeManager.suggestThemeName(from: source)
            },
            onCreateTheme: { name, content, applyTarget in
                try createAndApplyCustomTheme(
                    name: name,
                    content: content,
                    applyTarget: applyTarget
                )
            },
            onApplyTheme: { themeName, applyTarget in
                applyThemeSelection(themeName: themeName, applyTarget: applyTarget)
            },
            onDelete: { themeID in
                terminalThemeManager.deleteCustomTheme(id: themeID)
            },
            onSaveEdit: { themeID, name, content in
                try terminalThemeManager.updateCustomTheme(
                    id: themeID,
                    name: name,
                    content: content
                )
            }
        )
    }

    private func createAndApplyCustomTheme(
        name: String,
        content: String,
        applyTarget: TerminalThemeSelectionTarget
    ) throws {
        let theme = try terminalThemeManager.createCustomTheme(name: name, content: content)
        applyThemeSelection(themeName: theme.name, applyTarget: applyTarget)
    }

    private func applyThemeSelection(
        themeName: String,
        applyTarget: TerminalThemeSelectionTarget
    ) {
        let target = themeSelection.usePerAppearanceTheme ? applyTarget : .dark
        terminalThemeManager.selectTheme(named: themeName, for: target)
    }
}
