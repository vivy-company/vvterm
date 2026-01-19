import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Keychain Settings View

struct KeychainSettingsView: View {
    @State private var storedKeys: [SSHKeyEntry] = []
    @State private var showingAddKey = false
    @State private var showingGenerateKey = false
    @State private var showingDeleteConfirmation = false
    @State private var keyToDelete: SSHKeyEntry?
    @State private var keyToShowDetails: SSHKeyEntry?
    @State private var error: String?

    var body: some View {
        Group {
            if storedKeys.isEmpty {
                emptyKeysView
            } else {
                Form {
                    Section {
                        ForEach(storedKeys) { key in
                            Button {
                                keyToShowDetails = key
                            } label: {
                                SSHKeyRow(key: key)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    keyToDelete = key
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    keyToShowDetails = key
                                } label: {
                                    Label(String(localized: "Details"), systemImage: "info.circle")
                                }
                                .tint(.gray)

                                Button {
                                    if let publicKey = key.publicKey {
                                        copyToClipboard(publicKey)
                                    }
                                } label: {
                                    Label(String(localized: "Copy to Clipboard"), systemImage: "doc.on.doc")
                                }
                                .tint(.blue)
                                .disabled(key.publicKey == nil)
                            }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
            GenerateSSHKeySheet(onSave: { entry in
                loadKeys()
                keyToShowDetails = entry
            })
        }
        .sheet(item: $keyToShowDetails) { key in
            KeyDetailsSheet(keyEntry: key)
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
            Text(String(format: String(localized: "Are you sure you want to delete '%@'? This cannot be undone."), key.name))
        }
    }

    @ViewBuilder
    private var emptyKeysView: some View {
        let actions = HStack(spacing: 12) {
            Button("Generate New Key") {
                showingGenerateKey = true
            }
            .buttonStyle(.borderedProminent)

            Button("Import Key") {
                showingAddKey = true
            }
            .buttonStyle(.bordered)
        }

        if #available(iOS 17.0, macOS 14.0, *) {
            ContentUnavailableView {
                Label("No Keys Stored", systemImage: "key")
            } description: {
                Text("Add keys to quickly use them when creating new servers")
            } actions: {
                actions
            }
        } else {
            VStack(spacing: 12) {
                Label("No Keys Stored", systemImage: "key")
                    .font(.headline)
                Text("Add keys to quickly use them when creating new servers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions
            }
            .padding()
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
            self.error = String(format: String(localized: "Failed to delete key: %@"), error.localizedDescription)
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - SSH Key Row

private struct SSHKeyRow: View {
    let key: SSHKeyEntry

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
                    let relative = key.createdAt.formatted(.relative(presentation: .named))
                    Text(String(format: String(localized: "Added %@"), relative))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
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
                    Menu {
                        Button("Import Key File") {
                            showingKeyImporter = true
                        }

                        Button("Paste") {
                            pasteKeyFromClipboard()
                        }
                    } label: {
                        Label(keyContent.isEmpty ? "Add Private Key" : "Replace Private Key", systemImage: "key.fill")
                    }

                    if !keyContent.isEmpty {
                        Label(String(localized: "Key loaded"), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
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

    private func pasteKeyFromClipboard() {
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

    private func handleKeyImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                self.error = String(localized: "Cannot access the selected file")
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
                self.error = String(format: String(localized: "Failed to read key file: %@"), error.localizedDescription)
            }
        case .failure(let error):
            self.error = String(format: String(localized: "Failed to import key: %@"), error.localizedDescription)
        }
    }

    private func saveKey() {
        isSaving = true
        error = nil

        guard let keyData = keyContent.data(using: .utf8) else {
            error = String(localized: "Failed to encode key data")
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
            self.error = String(format: String(localized: "Failed to save key: %@"), error.localizedDescription)
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
    @State private var error: String?

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
                    Button("Generate") {
                        generateKey()
                    }
                    .disabled(!isValidForGeneration || isGenerating)
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
                let entry = try KeychainManager.shared.storeSSHKeyEntry(
                    name: name,
                    privateKey: key.privateKey,
                    passphrase: passphrase.isEmpty ? nil : passphrase,
                    keyType: key.keyType,
                    publicKey: key.publicKey
                )
                await MainActor.run {
                    self.isGenerating = false
                    onSave(entry)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = String(format: String(localized: "Failed to generate key: %@"), error.localizedDescription)
                    self.isGenerating = false
                }
            }
        }
    }
}

// MARK: - Key Details Sheet

struct KeyDetailsSheet: View {
    let keyEntry: SSHKeyEntry

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "Key Name"), value: keyEntry.name)
                    if let keyType = keyEntry.keyType {
                        LabeledContent(String(localized: "Key Type"), value: keyType.displayName)
                    }
                    LabeledContent(String(localized: "Added")) {
                        Text(keyEntry.createdAt, style: .date)
                    }
                    LabeledContent(String(localized: "Passphrase")) {
                        Text(keyEntry.hasPassphrase ? String(localized: "Protected") : "-")
                    }
                }

                Section {
                    if let publicKey = keyEntry.publicKey {
                        Text(publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            Button {
                                copyToClipboard(publicKey)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    Text(copied ? String(localized: "Copied") : String(localized: "Copy to Clipboard"))
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Spacer()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "No Public Key"))
                                .foregroundStyle(.secondary)
                            Text(String(localized: "This key was imported without a public key."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "Public Key"))
                } footer: {
                    Text(String(localized: "Add this to your server's ~/.ssh/authorized_keys file:"))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "SSH Key"))
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
                    Label(
                        copied ? String(localized: "Copied") : String(localized: "Copy to Clipboard"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
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
