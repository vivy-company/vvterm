import SwiftUI

// MARK: - Environment Form Sheet (Create/Edit)

struct EnvironmentFormSheet: View {
    @ObservedObject var serverManager: ServerManager
    let workspace: Workspace
    let environment: ServerEnvironment?
    let onSave: (Workspace, ServerEnvironment) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedColorHex: String = Workspace.defaultColors.first ?? "#007AFF"
    @State private var isSaving = false
    @State private var error: String?

    private let colorOptions = Workspace.defaultColors
    private var isEditing: Bool { environment != nil }

    init(
        serverManager: ServerManager,
        workspace: Workspace,
        environment: ServerEnvironment? = nil,
        onSave: @escaping (Workspace, ServerEnvironment) -> Void
    ) {
        self.serverManager = serverManager
        self.workspace = workspace
        self.environment = environment
        self.onSave = onSave

        if let environment {
            _name = State(initialValue: environment.name)
            _selectedColorHex = State(initialValue: environment.colorHex)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
            Section("Name") {
                TextField(String(localized: "Environment name"), text: $name)
#if os(iOS)
                    .textInputAutocapitalization(.words)
#endif
            }

                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(colorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color.fromHex(hex))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if selectedColorHex == hex {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 3)
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                            .font(.caption.bold())
                                    }
                                }
                                .onTapGesture {
                                    selectedColorHex = hex
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(
                isEditing
                ? String(localized: "Edit Environment")
                : String(localized: "New Environment")
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") {
                        saveEnvironment()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .frame(minWidth: 360, minHeight: 320)
        }
    }

    private func saveEnvironment() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if workspace.environments.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame && $0.id != environment?.id }) {
            error = String(localized: "An environment with this name already exists.")
            return
        }

        isSaving = true
        error = nil

        Task {
            do {
                if let environment {
                    let updatedEnvironment = ServerEnvironment(
                        id: environment.id,
                        name: trimmedName,
                        shortName: String(trimmedName.prefix(4)),
                        colorHex: selectedColorHex,
                        isBuiltIn: false
                    )
                    let updatedWorkspace = try await serverManager.updateEnvironment(updatedEnvironment, in: workspace)
                    await MainActor.run {
                        onSave(updatedWorkspace, updatedEnvironment)
                        dismiss()
                    }
                } else {
                    let newEnvironment = try serverManager.createCustomEnvironment(
                        name: trimmedName,
                        color: selectedColorHex
                    )
                    var updatedWorkspace = workspace
                    updatedWorkspace.environments.append(newEnvironment)

                    try await serverManager.updateWorkspace(updatedWorkspace)

                    await MainActor.run {
                        onSave(updatedWorkspace, newEnvironment)
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isSaving = false
                }
            }
        }
    }
}

#Preview {
    EnvironmentFormSheet(
        serverManager: ServerManager.shared,
        workspace: Workspace(name: "Default"),
        onSave: { _, _ in }
    )
}
