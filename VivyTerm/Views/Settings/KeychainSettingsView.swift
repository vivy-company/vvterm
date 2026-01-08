import SwiftUI
import UniformTypeIdentifiers

// MARK: - Keychain Settings View

struct KeychainSettingsView: View {
    @State private var storedKeys: [SSHKeyEntry] = []
    @State private var showingAddKey = false
    @State private var showingGenerateKey = false
    @State private var showingDeleteConfirmation = false
    @State private var showingPublicKey = false
    @State private var keyToDelete: SSHKeyEntry?
    @State private var keyToShowPublic: SSHKeyEntry?
    @State private var error: String?

    var body: some View {
        Group {
            if storedKeys.isEmpty {
                ContentUnavailableView {
                    Label("No Keys Stored", systemImage: "key")
                } description: {
                    Text("Add keys to quickly use them when creating new servers")
                } actions: {
                    HStack(spacing: 12) {
                        Button("Generate New Key") {
                            showingGenerateKey = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Import Key") {
                            showingAddKey = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Form {
                    Section {
                        ForEach(storedKeys) { key in
                            SSHKeyRow(
                                key: key,
                                onDelete: {
                                    keyToDelete = key
                                    showingDeleteConfirmation = true
                                },
                                onShowPublicKey: key.publicKey != nil ? {
                                    keyToShowPublic = key
                                    showingPublicKey = true
                                } : nil
                            )
                        }
                    } header: {
                        HStack {
                            Spacer()
                            Menu {
                                Button {
                                    showingGenerateKey = true
                                } label: {
                                    Label("Generate New Key", systemImage: "wand.and.stars")
                                }
                                Button {
                                    showingAddKey = true
                                } label: {
                                    Label("Import Key", systemImage: "square.and.arrow.down")
                                }
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
        .sheet(isPresented: $showingGenerateKey) {
            GenerateSSHKeySheet(onSave: { _ in
                loadKeys()
            })
        }
        .sheet(isPresented: $showingPublicKey) {
            if let key = keyToShowPublic {
                PublicKeySheet(keyEntry: key)
            }
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
    let onShowPublicKey: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: keyIcon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    if let keyType = key.keyType {
                        Text(keyType.displayName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
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

            if onShowPublicKey != nil {
                Button {
                    onShowPublicKey?()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Copy public key")
            }

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

    private var keyIcon: String {
        if let keyType = key.keyType {
            switch keyType {
            case .ed25519: return "cpu"
            case .rsa4096: return "lock.doc.fill"
            }
        }
        return key.hasPassphrase ? "lock.shield.fill" : "key.fill"
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

// MARK: - Generate SSH Key Sheet

struct GenerateSSHKeySheet: View {
    let onSave: (SSHKeyEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var keyType: SSHKeyType = .ed25519
    @State private var passphrase: String = ""
    @State private var confirmPassphrase: String = ""
    @State private var isGenerating = false
    @State private var generatedKey: GeneratedSSHKey?
    @State private var error: String?
    @State private var showingPublicKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Name") {
                    TextField("e.g., Personal MacBook, Work Key", text: $name)
                }

                Section {
                    Picker("Algorithm", selection: $keyType) {
                        ForEach(SSHKeyType.allCases) { type in
                            VStack(alignment: .leading) {
                                Text(type.displayName)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Key Type")
                } footer: {
                    Text(keyType.description)
                }

                Section {
                    SecureField("Passphrase", text: $passphrase)
                    if !passphrase.isEmpty {
                        SecureField("Confirm passphrase", text: $confirmPassphrase)
                    }
                } header: {
                    Text("Passphrase (Optional)")
                } footer: {
                    Text("Protect your key with a passphrase. Leave empty for no protection.")
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                if let key = generatedKey {
                    Section("Generated Key") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Key generated successfully")
                                    .foregroundStyle(.green)
                            }

                            Text("Fingerprint:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(key.fingerprint)
                                .font(.caption.monospaced())

                            Button("View Public Key") {
                                showingPublicKey = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Generate SSH Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if generatedKey != nil {
                        Button("Save") {
                            saveKey()
                        }
                    } else {
                        Button("Generate") {
                            generateKey()
                        }
                        .disabled(!isValidForGeneration || isGenerating)
                    }
                }
            }
            .sheet(isPresented: $showingPublicKey) {
                if let key = generatedKey {
                    PublicKeyDisplaySheet(publicKey: key.publicKey, fingerprint: key.fingerprint)
                }
            }
        }
    }

    private var isValidForGeneration: Bool {
        !name.isEmpty && (passphrase.isEmpty || passphrase == confirmPassphrase)
    }

    private func generateKey() {
        isGenerating = true
        error = nil

        Task {
            do {
                let comment = name.replacingOccurrences(of: " ", with: "_")
                let key = try SSHKeyGenerator.generate(type: keyType, comment: comment)
                await MainActor.run {
                    self.generatedKey = key
                    self.isGenerating = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to generate key: \(error.localizedDescription)"
                    self.isGenerating = false
                }
            }
        }
    }

    private func saveKey() {
        guard let key = generatedKey else { return }

        do {
            let entry = try KeychainManager.shared.storeSSHKeyEntry(
                name: name,
                privateKey: key.privateKey,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                keyType: key.keyType,
                publicKey: key.publicKey
            )
            onSave(entry)
            dismiss()
        } catch {
            self.error = "Failed to save key: \(error.localizedDescription)"
        }
    }
}

// MARK: - Public Key Sheet (for existing keys)

struct PublicKeySheet: View {
    let keyEntry: SSHKeyEntry

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let publicKey = keyEntry.publicKey {
                    Text("Add this to your server's ~/.ssh/authorized_keys file:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    ScrollView {
                        Text(publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal)

                    Button {
                        copyToClipboard(publicKey)
                    } label: {
                        Label(copied ? "Copied" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ContentUnavailableView {
                        Label("No Public Key", systemImage: "key.slash")
                    } description: {
                        Text("This key was imported without a public key.")
                    }
                }
            }
            .padding(.vertical)
            .navigationTitle("Public Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
    }
}

// MARK: - Public Key Display Sheet (for newly generated keys)

struct PublicKeyDisplaySheet: View {
    let publicKey: String
    let fingerprint: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fingerprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.system(.caption, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Text("Add this to your server's ~/.ssh/authorized_keys file:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ScrollView {
                    Text(publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)

                Button {
                    copyToClipboard(publicKey)
                } label: {
                    Label(copied ? "Copied" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical)
            .navigationTitle("Public Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
    }
}

// MARK: - Preview

#Preview {
    KeychainSettingsView()
}
