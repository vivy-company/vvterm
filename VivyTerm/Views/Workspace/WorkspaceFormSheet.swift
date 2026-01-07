import SwiftUI

// MARK: - Workspace Form Sheet (Create/Edit)

struct WorkspaceFormSheet: View {
    @ObservedObject var serverManager: ServerManager
    let workspace: Workspace?
    let onSave: (Workspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storeManager = StoreManager.shared

    @State private var name: String = ""
    @State private var selectedColor: Color = .blue
    @State private var showingProUpgrade = false
    @State private var isSaving = false
    @State private var error: String?

    private var isEditing: Bool { workspace != nil }

    private var isAtLimit: Bool {
        !isEditing && !serverManager.canAddWorkspace
    }

    let availableColors: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .cyan, .indigo
    ]

    init(
        serverManager: ServerManager,
        workspace: Workspace? = nil,
        onSave: @escaping (Workspace) -> Void
    ) {
        self.serverManager = serverManager
        self.workspace = workspace
        self.onSave = onSave

        if let workspace = workspace {
            _name = State(initialValue: workspace.name)
            _selectedColor = State(initialValue: Color.fromHex(workspace.colorHex))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            DetailHeaderBar(showsBackground: false) {
                Text(isEditing ? "Edit Workspace" : "New Workspace")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Limit Banner
                    if isAtLimit {
                        ProLimitBanner(
                            title: "Workspace Limit Reached",
                            message: "Upgrade to Pro for unlimited workspaces."
                        ) {
                            showingProUpgrade = true
                        }
                    }

                    // Name field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name")
                            .font(.headline)

                        TextField("Workspace name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                if !name.isEmpty && !isAtLimit {
                                    saveWorkspace()
                                }
                            }
                    }

                    // Color picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.headline)

                        HStack(spacing: 12) {
                            ForEach(availableColors, id: \.self) { color in
                                Circle()
                                    .fill(color)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if selectedColor == color {
                                            Circle()
                                                .strokeBorder(.white, lineWidth: 3)
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                                .font(.caption)
                                        }
                                    }
                                    .onTapGesture {
                                        selectedColor = color
                                    }
                            }
                        }
                    }

                    // Error message
                    if let error = error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                if isEditing {
                    Button(role: .destructive) {
                        deleteWorkspace()
                    } label: {
                        Text("Delete")
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Create") {
                    saveWorkspace()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || isAtLimit)
            }
            .padding()
        }
        .frame(width: 450)
        .frame(minHeight: 280, maxHeight: 400)
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeSheet()
        }
    }

    // MARK: - Actions

    private func saveWorkspace() {
        isSaving = true
        error = nil

        Task {
            do {
                let colorHex = selectedColor.toHex()

                let newWorkspace = Workspace(
                    id: workspace?.id ?? UUID(),
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    colorHex: colorHex,
                    icon: workspace?.icon,
                    order: workspace?.order ?? serverManager.workspaces.count,
                    environments: workspace?.environments ?? ServerEnvironment.builtInEnvironments,
                    lastSelectedEnvironmentId: workspace?.lastSelectedEnvironmentId,
                    lastSelectedServerId: workspace?.lastSelectedServerId,
                    createdAt: workspace?.createdAt ?? Date()
                )

                if isEditing {
                    try await serverManager.updateWorkspace(newWorkspace)
                } else {
                    try await serverManager.addWorkspace(newWorkspace)
                }

                await MainActor.run {
                    onSave(newWorkspace)
                    dismiss()
                }
            } catch let error as VivyTermError {
                await MainActor.run {
                    if case .proRequired = error {
                        self.showingProUpgrade = true
                    } else {
                        self.error = error.localizedDescription
                    }
                    self.isSaving = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isSaving = false
                }
            }
        }
    }

    private func deleteWorkspace() {
        guard let workspace = workspace else { return }

        Task {
            do {
                try await serverManager.deleteWorkspace(workspace)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Color Extension

extension Color {
    func toHex() -> String {
        #if os(macOS)
        guard let components = NSColor(self).cgColor.components, components.count >= 3 else { return "#0000FF" }
        #else
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return "#0000FF" }
        #endif

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Preview

#Preview {
    WorkspaceFormSheet(
        serverManager: ServerManager.shared,
        onSave: { _ in }
    )
}
