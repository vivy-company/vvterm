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
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
                    .tint(.secondary)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(role: serverFormConfirmationRole(isEditing: isEditing), action: onSave) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else if isEditing {
                        Label("Save", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    } else {
                        Text(String(localized: "Add"))
                    }
                }
                .tint(isEditing ? Color.blue : nil)
                .accessibilityLabel(isEditing ? Text("Save") : Text("Add"))
                .disabled(saveButtonDisabled)
            }
        }
    }

    private func serverFormConfirmationRole(isEditing: Bool) -> ButtonRole? {
        if #available(iOS 26, *), isEditing {
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
