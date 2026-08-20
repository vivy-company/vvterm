#if os(macOS)
import SwiftUI

extension ThemeBuilderSheet {
    func platformThemeNameField(name: Binding<String>) -> some View {
        TextField("Name", text: name, prompt: Text("Custom Theme"))
    }

    func platformColorField<Swatch: View>(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        swatch: Swatch
    ) -> some View {
        HStack(spacing: 10) {
            swatch

            TextField(label, text: text, prompt: Text(placeholder))
                .font(.system(.body, design: .monospaced))
        }
    }

    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: LocalizedStringKey(title)) {
                dismiss()
            }

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
    }

    private var macActionRow: some View {
        HStack(spacing: 10) {
            if onDeleteRequest != nil {
                Button("Remove Theme", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
#endif
