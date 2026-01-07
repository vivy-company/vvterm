import SwiftUI
import UniformTypeIdentifiers

// MARK: - Keychain Settings View

struct KeychainSettingsView: View {
    @State private var storedKeys: [SSHKeyEntry] = []
    @State private var showingAddKey = false
    @State private var showingDeleteConfirmation = false
    @State private var keyToDelete: SSHKeyEntry?
    @State private var error: String?

    var body: some View {
        Group {
            if storedKeys.isEmpty {
                ContentUnavailableView {
                    Label("No Keys Stored", systemImage: "key")
                } description: {
                    Text("Add keys to quickly use them when creating new servers")
                } actions: {
                    Button("Add Key") {
                        showingAddKey = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Form {
                    Section {
                        ForEach(storedKeys) { key in
                            SSHKeyRow(key: key, onDelete: {
                                keyToDelete = key
                                showingDeleteConfirmation = true
                            })
                        }
                    } header: {
                        HStack {
                            Spacer()
                            Button {
                                showingAddKey = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Keys are stored securely in your device's Keychain. Passphrases are stored separately.")
                    }

                    if let error = error {
                        Section {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .onAppear {
            loadKeys()
        }
        .sheet(isPresented: $showingAddKey) {
            AddSSHKeySheet(onSave: { _ in
                loadKeys()
            })
        }
        .confirmationDialog(
            "Delete SSH Key",
            isPresented: $showingDeleteConfirmation,
            presenting: keyToDelete
        ) { key in
            Button("Delete", role: .destructive) {
                deleteKey(key)
            }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text("Are you sure you want to delete '\(key.name)'? This cannot be undone.")
        }
    }

    private func loadKeys() {
        storedKeys = KeychainManager.shared.getStoredSSHKeys()
    }

    private func deleteKey(_ key: SSHKeyEntry) {
        do {
            try KeychainManager.shared.deleteStoredSSHKey(key.id)
            loadKeys()
            error = nil
        } catch {
            self.error = "Failed to delete key: \(error.localizedDescription)"
        }
    }
}

// MARK: - SSH Key Row

private struct SSHKeyRow: View {
    let key: SSHKeyEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: key.hasPassphrase ? "lock.shield.fill" : "key.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    if key.hasPassphrase {
                        Label("Protected", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text("Added \(key.createdAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add SSH Key Sheet

struct AddSSHKeySheet: View {
    let onSave: (SSHKeyEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var keyContent: String = ""
    @State private var passphrase: String = ""
    @State private var showingKeyImporter = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Name") {
                    TextField("e.g., Personal MacBook, Work Key", text: $name)
                }

                Section("Private Key") {
                    HStack {
                        Button("Import Key File") {
                            showingKeyImporter = true
                        }

                        Button("Paste") {
                            #if os(iOS)
                            if let key = UIPasteboard.general.string {
                                keyContent = key
                                if name.isEmpty {
                                    name = extractKeyName(from: key)
                                }
                            }
                            #elseif os(macOS)
                            if let key = NSPasteboard.general.string(forType: .string) {
                                keyContent = key
                                if name.isEmpty {
                                    name = extractKeyName(from: key)
                                }
                            }
                            #endif
                        }
                    }

                    if keyContent.isEmpty {
                        Text("Import your private key file (id_rsa, id_ed25519, etc.) or paste the contents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key loaded (\(keyContent.count) characters)")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section {
                    SecureField("Key passphrase", text: $passphrase)
                } header: {
                    Text("Passphrase (Optional)")
                } footer: {
                    Text("If your key is encrypted with a passphrase, enter it here. Leave empty for keys without passphrase.")
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add SSH Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveKey()
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .fileImporter(
                isPresented: $showingKeyImporter,
                allowedContentTypes: [.data, .text],
                allowsMultipleSelection: false
            ) { result in
                handleKeyImport(result)
            }
        }
    }

    private var isValid: Bool {
        !name.isEmpty && !keyContent.isEmpty
    }

    private func extractKeyName(from keyContent: String) -> String {
        // Try to extract name from key comment (last part of public key or first line comment)
        if keyContent.contains("PRIVATE KEY") {
            return ""
        }
        return ""
    }

    private func handleKeyImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                self.error = "Cannot access the selected file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                keyContent = content

                // Auto-fill name from filename
                if name.isEmpty {
                    let filename = url.deletingPathExtension().lastPathComponent
                    name = filename.replacingOccurrences(of: "id_", with: "").capitalized + " Key"
                }
            } catch {
                self.error = "Failed to read key file: \(error.localizedDescription)"
            }
        case .failure(let error):
            self.error = "Failed to import key: \(error.localizedDescription)"
        }
    }

    private func saveKey() {
        isSaving = true
        error = nil

        guard let keyData = keyContent.data(using: .utf8) else {
            error = "Failed to encode key data"
            isSaving = false
            return
        }

        do {
            let entry = try KeychainManager.shared.storeSSHKeyEntry(
                name: name,
                privateKey: keyData,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            onSave(entry)
            dismiss()
        } catch {
            self.error = "Failed to save key: \(error.localizedDescription)"
            isSaving = false
        }
    }
}

// MARK: - Preview

#Preview {
    KeychainSettingsView()
}
