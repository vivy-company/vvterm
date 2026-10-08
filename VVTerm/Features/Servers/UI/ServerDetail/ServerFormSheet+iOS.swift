#if os(iOS)
import SwiftUI

extension ServerFormSheet {
    var platformBody: some View {
        formContent
    }
}

extension MoveServerSheet {
    var platformBody: some View {
        formContent
    }
}

extension View {
    func serverFormPlatformStyle(title: String) -> some View {
        environment(\.defaultMinListRowHeight, 34)
            .modifier(ServerFormCompactListSectionSpacingModifier())
            .modifier(ServerFormTransparentNavigationBarModifier())
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(title)
    }

    func serverFormPlatformActions(
        isEditing: Bool,
        isSaving: Bool,
        saveButtonDisabled: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if #available(iOS 26, *) {
                    Button(role: .cancel, action: onCancel)
                        .disabled(isSaving)
                } else {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(role: serverFormConfirmationRole, action: onSave) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(isEditing ? String(localized: "Save") : String(localized: "Add"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                }
                .tint(.blue)
                .accessibilityLabel(isEditing ? Text("Save") : Text("Add"))
                .disabled(saveButtonDisabled)
            }
        }
    }

    private var serverFormConfirmationRole: ButtonRole? {
        if #available(iOS 26, *) {
            return .confirm
        }
        return nil
    }

    func moveServerPlatformActions(
        isMoving: Bool,
        moveButtonDisabled: Bool,
        onCancel: @escaping () -> Void,
        onMove: @escaping () -> Void
    ) -> some View {
        navigationTitle("Move Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isMoving)
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onMove) {
                        if isMoving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Move")
                        }
                    }
                    .disabled(moveButtonDisabled)
                }
            }
    }
}

private struct ServerFormCompactListSectionSpacingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.listSectionSpacing(.compact)
        } else {
            content
        }
    }
}

private struct ServerFormTransparentNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}
#endif
