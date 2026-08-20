#if os(iOS)
import SwiftUI

extension CustomThemeSaveSheet {
    func platformThemeNameField(name: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text("Name")
            Spacer(minLength: 8)
            TextField("", text: name, prompt: Text("Custom Theme"))
                .multilineTextAlignment(.trailing)
        }
    }

    var platformBody: some View {
        NavigationStack {
            formContent
                .navigationTitle("Save Custom Theme")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(!canSave)
                    }
                }
        }
        .adaptiveSoftScrollEdges()
    }
}
#endif
