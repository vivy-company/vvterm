#if os(macOS)
import SwiftUI

extension CustomThemeSaveSheet {
    func platformThemeNameField(name: Binding<String>) -> some View {
        TextField("Name", text: name, prompt: Text("Custom Theme"))
    }

    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Save Custom Theme") {
                dismiss()
            }

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
        .frame(width: 700, height: usePerAppearanceTheme ? 300 : 250)
    }

    private var macActionRow: some View {
        HStack(spacing: 10) {
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
