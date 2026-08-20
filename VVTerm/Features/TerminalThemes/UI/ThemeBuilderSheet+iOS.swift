#if os(iOS)
import SwiftUI

extension ThemeBuilderSheet {
    func platformThemeNameField(name: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text("Name")
            Spacer(minLength: 8)
            TextField("", text: name, prompt: Text("Custom Theme"))
                .multilineTextAlignment(.trailing)
        }
    }

    func platformColorField<Swatch: View>(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        swatch: Swatch
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)

            Spacer(minLength: 8)

            TextField("", text: text, prompt: Text(placeholder))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 110, maxWidth: 170, alignment: .trailing)

            swatch
        }
    }

    var platformBody: some View {
        NavigationStack {
            formContent
                .environment(\.defaultMinListRowHeight, 34)
                .modifier(ThemeBuilderCompactListSectionSpacingModifier())
                .modifier(ThemeBuilderTransparentNavigationBarModifier())
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarAppearance(
                    backgroundColor: .clear,
                    isTranslucent: true,
                    shadowColor: .clear
                )
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .tint(.secondary)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(!canSave)
                    }
                    if onDeleteRequest != nil {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("Remove Theme", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                            .tint(.red)

                            Spacer(minLength: 0)
                        }
                    }
                }
        }
    }
}

private struct ThemeBuilderCompactListSectionSpacingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.listSectionSpacing(.compact)
        } else {
            content
        }
    }
}

private struct ThemeBuilderTransparentNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}
#endif
