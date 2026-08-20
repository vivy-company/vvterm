import SwiftUI

struct ThemeBuilderSheet: View {
    let usePerAppearanceTheme: Bool
    let showApplyTarget: Bool
    let title: String
    let onDeleteRequest: (() -> Void)?
    let onSave: (String, String, TerminalThemeSelectionTarget) throws -> Void

    @Environment(\.dismiss) var dismiss

    @State private var name: String
    @State private var draft: TerminalThemeDraft
    @State private var applyTarget: TerminalThemeSelectionTarget
    @State private var errorMessage: String?
    @State var showingDeleteConfirmation = false

    init(
        usePerAppearanceTheme: Bool,
        showApplyTarget: Bool? = nil,
        title: String = "Theme Builder",
        initialName: String = "Custom Theme",
        initialContent: String? = nil,
        initialApplyTarget: TerminalThemeSelectionTarget = .dark,
        onDeleteRequest: (() -> Void)? = nil,
        onSave: @escaping (String, String, TerminalThemeSelectionTarget) throws -> Void
    ) {
        self.usePerAppearanceTheme = usePerAppearanceTheme
        self.showApplyTarget = showApplyTarget ?? usePerAppearanceTheme
        self.title = title
        self.onDeleteRequest = onDeleteRequest
        self.onSave = onSave

        _name = State(initialValue: initialName)
        _draft = State(initialValue: TerminalThemeDraft.decode(initialContent))
        _applyTarget = State(initialValue: initialApplyTarget)
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.hasValidBuilderValues
    }

    private var previewBackground: Color {
        previewColor(for: draft.background, fallback: Color.fromHex("#101418"))
    }

    private var previewForeground: Color {
        previewColor(for: draft.foreground, fallback: Color.fromHex("#D8E0EA"))
    }

    private var previewCursorColor: Color {
        previewColor(for: draft.cursorColor, fallback: Color.fromHex("#F8B26A"))
    }

    private var previewCursorText: Color {
        previewColor(for: draft.cursorText, fallback: previewBackground)
    }

    private var previewSelectionBackground: Color {
        previewColor(for: draft.selectionBackground, fallback: Color.fromHex("#2E3A46"))
    }

    private var previewSelectionForeground: Color {
        previewColor(for: draft.selectionForeground, fallback: previewForeground)
    }

    var body: some View {
        platformBody
        .alert("Delete Custom Theme?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDeleteRequest?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .adaptiveSoftScrollEdges()
    }

    var formContent: some View {
        Form {
                Section {
                    platformThemeNameField(name: $name)
                } header: {
                    sectionHeader("Theme")
                }

                Section {
                    colorField(String(localized: "Background"), text: $draft.background, placeholder: "#101418", fallback: Color.fromHex("#101418"))
                    colorField(String(localized: "Foreground"), text: $draft.foreground, placeholder: "#D8E0EA", fallback: Color.fromHex("#D8E0EA"))
                } header: {
                    sectionHeader("Required Colors")
                }

                Section {
                    colorField(String(localized: "Cursor"), text: $draft.cursorColor, placeholder: "#F8B26A", fallback: Color.fromHex("#F8B26A"))
                    colorField(String(localized: "Cursor Text"), text: $draft.cursorText, placeholder: "#101418", fallback: previewBackground)
                    colorField(String(localized: "Selection Background"), text: $draft.selectionBackground, placeholder: "#2E3A46", fallback: Color.fromHex("#2E3A46"))
                    colorField(String(localized: "Selection Foreground"), text: $draft.selectionForeground, placeholder: "#D8E0EA", fallback: Color.fromHex("#D8E0EA"))
                } header: {
                    sectionHeader("Optional Colors")
                } footer: {
                    Text("Leave optional values empty to keep defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(0..<16, id: \.self) { index in
                        colorField(
                            String(
                                format: String(localized: "Palette %lld"),
                                Int64(index)
                            ),
                            text: paletteColorBinding(index),
                            placeholder: paletteFallbackHex(index),
                            fallback: Color.fromHex(paletteFallbackHex(index))
                        )
                    }
                } header: {
                    sectionHeader("Palette (0-15)")
                } footer: {
                    Text("Optional ANSI palette entries. Leave empty to use Ghostty defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $draft.advancedLines)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 88)
                } header: {
                    sectionHeader("Advanced Theme Values")
                } footer: {
                    Text("Only supported visual theme keys can be saved. Remove unsafe or invalid lines to repair this theme.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    terminalPreview
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 126)
                } header: {
                    sectionHeader("Preview")
                }

                if showApplyTarget {
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

    private var terminalPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("restty@prod-web-01:~$ printenv APP_ENV")

            HStack(spacing: 6) {
                Text("APP_ENV=")
                    .foregroundStyle(previewForeground.opacity(0.78))
                Text("production")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(previewSelectionBackground)
                    .foregroundStyle(previewSelectionForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            HStack(spacing: 6) {
                Text("cursor>")
                    .foregroundStyle(previewForeground.opacity(0.78))
                Text("A")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(previewCursorColor)
                    .foregroundStyle(previewCursorText)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("selection")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(previewSelectionBackground)
                    .foregroundStyle(previewSelectionForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Rectangle()
                .fill(previewForeground.opacity(0.16))
                .frame(height: 1)

            Text("ANSI Palette")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(previewForeground.opacity(0.82))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 26), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<16, id: \.self) { index in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palettePreviewColor(index))
                            .frame(height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(previewForeground.opacity(0.18), lineWidth: 1)
                            )
                        Text("\(index)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(previewForeground.opacity(0.8))
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .foregroundStyle(previewForeground)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(previewBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(previewForeground.opacity(0.15), lineWidth: 1)
        )
    }

    private func colorField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        fallback: Color
    ) -> some View {
        platformColorField(
            label,
            text: text,
            placeholder: placeholder,
            swatch: ThemeBuilderColorSwatchPicker(
                label: label,
                text: text,
                fallback: fallback
            )
        )
    }

    private func paletteColorBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.paletteColors[index] },
            set: { draft.paletteColors[index] = $0 }
        )
    }

    private func paletteFallbackHex(_ index: Int) -> String {
        let defaults = [
            "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
            "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
            "#666666", "#D54E53", "#B9CA4A", "#E7C547",
            "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA"
        ]
        guard defaults.indices.contains(index) else { return "#808080" }
        return defaults[index]
    }

    private func palettePreviewColor(_ index: Int) -> Color {
        guard draft.paletteColors.indices.contains(index) else {
            return Color.fromHex(paletteFallbackHex(index))
        }
        return previewColor(
            for: draft.paletteColors[index],
            fallback: Color.fromHex(paletteFallbackHex(index))
        )
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
                try draft.encodedContent(),
                showApplyTarget ? applyTarget : .dark
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func previewColor(for value: String, fallback: Color) -> Color {
        guard TerminalThemeValidator.isValidHexColor(value) else { return fallback }
        return Color.fromHex(value)
    }
}

private struct ThemeBuilderColorSwatchPicker: View {
    let label: String
    @Binding var text: String
    let fallback: Color

    private var swatchColor: Color {
        guard TerminalThemeValidator.isValidHexColor(text) else { return fallback }
        return Color.fromHex(text)
    }

    var body: some View {
        let pickColorLabel = String(
            format: String(localized: "Pick %@ color"),
            label
        )

        ColorPicker(
            pickColorLabel,
            selection: Binding(
                get: { swatchColor },
                set: { selectedColor in
                    text = selectedColor.toHex()
                }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .accessibilityLabel(pickColorLabel)
    }
}
