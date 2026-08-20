#if os(macOS)
import SwiftUI

extension ServerFormSheet {
    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(
                title: isEditing ? "Edit Server" : "Add Server",
                onClose: { dismiss() },
                isCloseDisabled: isSaving
            )

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
    }

    private var macActionRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }
            .disabled(isSaving)

            Button {
                saveServer()
            } label: {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Saving..."))
                    }
                } else {
                    Text(isEditing ? String(localized: "Save") : String(localized: "Add"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(saveButtonDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

extension MoveServerSheet {
    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(
                title: "Move Server",
                onClose: { dismiss() },
                isCloseDisabled: isMoving
            )

            Divider()

            formContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            macActionRow
        }
    }

    private var macActionRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button("Cancel") {
                dismiss()
            }
            .disabled(isMoving)

            Button {
                moveServer()
            } label: {
                if isMoving {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Moving..."))
                    }
                } else {
                    Text("Move")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(moveButtonDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

extension View {
    func serverFormPlatformStyle(title: String) -> some View {
        self
    }

    func serverFormPlatformActions(
        isEditing: Bool,
        isSaving: Bool,
        saveButtonDisabled: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) -> some View {
        self
    }

    func moveServerPlatformActions(
        isMoving: Bool,
        moveButtonDisabled: Bool,
        onCancel: @escaping () -> Void,
        onMove: @escaping () -> Void
    ) -> some View {
        self
    }
}
#endif
