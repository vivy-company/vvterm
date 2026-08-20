import SwiftUI

// MARK: - Workspace Form Sheet (Create/Edit)

struct WorkspaceFormSheet: View {
    let serverManager: ServerManager
    @ObservedObject private var stateStore: ServerStateStore
    let workspace: Workspace?
    let onSave: (Workspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeManager: StoreManager

    @State private var name: String = ""
    @State private var selectedColor: Color = .blue
    @State private var showingUpgradeSheet = false
    @State private var workspaceToDelete: Workspace?
    @State private var isSaving = false
    @State private var error: String?

    private var isEditing: Bool { workspace != nil }

    private var isAtLimit: Bool {
        !isEditing && !stateStore.canAddWorkspace(hasProAccess: storeManager.allowsProFeatures)
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
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
        self.workspace = workspace
        self.onSave = onSave

        if let workspace = workspace {
            _name = State(initialValue: workspace.name)
            _selectedColor = State(initialValue: Color.fromHex(workspace.colorHex))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Limit Banner
                if isAtLimit {
                    Section {
                        ProLimitBanner(
                            title: String(localized: "Workspace Limit Reached"),
                            message: String(localized: "Pro unlocks unlimited workspaces, servers, and connections.")
                        ) {
                            showingUpgradeSheet = true
                        }
                    }
                }

                // Name field
                Section("Name") {
                    TextField("Workspace name", text: $name)
                        .onSubmit {
                            if !name.isEmpty && !isAtLimit {
                                saveWorkspace()
                            }
                        }
                }

                // Color picker
                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(availableColors, id: \.self) { color in
                            Circle()
                                .fill(color)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if selectedColor == color {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 3)
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                            .font(.caption.bold())
                                    }
                                }
                                .onTapGesture {
                                    selectedColor = color
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Error message
                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                // Delete button for editing
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            workspaceToDelete = workspace
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Workspace")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? String(localized: "Edit Workspace") : String(localized: "New Workspace"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "Save") : String(localized: "Create")) {
                        saveWorkspace()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || isAtLimit)
                }
            }
            .proUpgradePresentation(isPresented: $showingUpgradeSheet, source: .workspaceLimit)
            .alert("Delete Workspace?", isPresented: Binding(
                get: { workspaceToDelete != nil },
                set: { if !$0 { workspaceToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    deleteWorkspace()
                }
            } message: {
                Text(deleteWarningText(for: workspaceToDelete))
            }
        }
        .adaptiveSoftScrollEdges()
    }

    // MARK: - Actions

    private func saveWorkspace() {
        isSaving = true
        error = nil

        Task {
            do {
                let colorHex = selectedColor.toHex()

                let newWorkspace = stateStore.makeWorkspaceSaveCandidate(
                    editing: workspace,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    colorHex: colorHex
                )

                if isEditing {
                    try await serverManager.updateWorkspace(newWorkspace)
                } else {
                    try await serverManager.addWorkspace(
                        newWorkspace,
                        hasProAccess: storeManager.allowsProFeatures
                    )
                }

                await MainActor.run {
                    onSave(newWorkspace)
                    dismiss()
                }
            } catch let error as VVTermError {
                await MainActor.run {
                    if case .proRequired = error {
                        self.showingUpgradeSheet = true
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

    private func deleteWarningText(for workspace: Workspace?) -> String {
        guard let workspace else {
            return String(localized: "This will delete the workspace and all servers in it. This cannot be undone.")
        }
        let count = stateStore.servers(in: workspace, environment: nil).count
        if count == 0 {
            return String(localized: "This will delete the workspace. This cannot be undone.")
        }
        if count == 1 {
            return String(localized: "This will delete the workspace and its 1 server. This cannot be undone.")
        }
        return String(
            format: String(localized: "This will delete the workspace and all %lld servers in it. This cannot be undone."),
            Int64(count)
        )
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
