import SwiftUI
import UniformTypeIdentifiers

enum SSHKeySettingsFailurePresentation {
    static func message(
        for operation: SSHKeySettingsCoordinator.Operation,
        failure: SSHKeySettingsFailure
    ) -> String {
        let format = switch operation {
        case .importKey:
            String(localized: "Failed to save key: %@")
        case .generateKey:
            String(localized: "Failed to generate key: %@")
        case .deleteKey:
            String(localized: "Failed to delete key: %@")
        }
        return String(format: format, details(for: failure))
    }

    static func details(for failure: SSHKeySettingsFailure) -> String {
        switch failure {
        case .keychain(let status):
            "Keychain error: \(status)"
        case .keychainEncodingFailed:
            "Failed to encode data for Keychain"
        case .keychainDecodingFailed:
            "Failed to decode data from Keychain"
        case .keychainItemNotFound:
            "Item not found in Keychain"
        case .credentialServerMismatch:
            "Credentials do not belong to this server"
        case .keychainCopyVerificationFailed:
            "VVTerm could not verify the copied Keychain item"
        case .keyGenerationFailed:
            String(localized: "Failed to generate SSH key")
        case .keyEncodingFailed:
            String(localized: "Failed to encode key data")
        case .rsaExportFailed:
            String(localized: "Failed to export RSA key")
        case .invalidKeyData:
            String(localized: "Invalid key data")
        case .unavailable:
            String(localized: "The SSH key operation could not be completed.")
        }
    }
}

// MARK: - Keychain Settings View

struct KeychainSettingsView: View {
    @EnvironmentObject private var coordinator: SSHKeySettingsCoordinator
    @State private var showingAddKey = false
    @State private var showingGenerateKey = false
    @State private var keyToDelete: SSHKeyEntry?
    @State var keyToShowDetails: SSHKeyEntry?

    var body: some View {
        Group {
            if coordinator.keys.isEmpty {
                emptyKeysView
            } else {
                Form {
                    Section {
                        ForEach(coordinator.keys) { key in
                            platformKeyRow(for: key)
                        }
                    } footer: {
                        Text("Keys are stored securely in your device's Keychain. Passphrases are stored separately.")
                    }

                    if let deleteError {
                        Section {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(deleteError)
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
        .adaptiveSoftScrollEdges()
        .onAppear {
            coordinator.clearFailure(for: .deleteKey)
            coordinator.loadKeys()
        }
        .sheet(isPresented: $showingAddKey) {
            AddSSHKeySheet(onSave: { _ in })
                .adaptiveSoftScrollEdges()
        }
        .sheet(isPresented: $showingGenerateKey) {
            GenerateSSHKeySheet(onSave: { entry in
                keyToShowDetails = entry
            })
            .adaptiveSoftScrollEdges()
        }
        .sheet(item: $keyToShowDetails) { key in
            KeyDetailsSheet(keyEntry: key)
                .adaptiveSoftScrollEdges()
        }
        .alert(
            "Delete SSH Key",
            isPresented: Binding(
                get: { keyToDelete != nil },
                set: { if !$0 { keyToDelete = nil } }
            ),
            presenting: keyToDelete
        ) { key in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                coordinator.deleteKey(key)
            }
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

    private var deleteError: String? {
        guard let failure = coordinator.failure(for: .deleteKey) else {
            return nil
        }
        return SSHKeySettingsFailurePresentation.message(
            for: .deleteKey,
            failure: failure
        )
    }

    private func copyToClipboard(_ text: String) {
        Clipboard.copy(text)
    }

    @ViewBuilder
    func keyActions(for key: SSHKeyEntry) -> some View {
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

        Button(role: .destructive) {
            keyToDelete = key
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - SSH Key Row

struct SSHKeyRow: View {
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
    @EnvironmentObject private var coordinator: SSHKeySettingsCoordinator

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

                if let presentedError {
                    Section {
                        Text(presentedError)
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
        .adaptiveSoftScrollEdges()
        .onAppear {
            coordinator.clearFailure(for: .importKey)
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
        if let key = Clipboard.readString() {
            keyContent = key
            if name.isEmpty {
                name = extractKeyName(from: key)
            }
        }
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

        guard let entry = coordinator.storeImportedKey(
            name: name,
            privateKey: keyData,
            passphrase: passphrase.isEmpty ? nil : passphrase
        ) else {
            isSaving = false
            return
        }
        onSave(entry)
        dismiss()
    }

    private var presentedError: String? {
        if let error {
            return error
        }
        guard let failure = coordinator.failure(for: .importKey) else {
            return nil
        }
        return SSHKeySettingsFailurePresentation.message(
            for: .importKey,
            failure: failure
        )
    }
}

// MARK: - Generate SSH Key Sheet

struct GenerateSSHKeySheet: View {
    let onSave: (SSHKeyEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: SSHKeySettingsCoordinator

    @State private var name: String = ""
    @State private var keyType: SSHKeyType = .ed25519
    @State private var passphrase: String = ""
    @State private var confirmPassphrase: String = ""
    @State private var isGenerating = false

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

                if let generationError {
                    Section {
                        Text(generationError)
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
        .adaptiveSoftScrollEdges()
        .onAppear {
            coordinator.clearFailure(for: .generateKey)
        }
    }

    private var isValidForGeneration: Bool {
        !name.isEmpty && (passphrase.isEmpty || passphrase == confirmPassphrase)
    }

    private func generateKey() {
        isGenerating = true

        Task {
            if let entry = coordinator.generateAndStoreKey(
                name: name,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                keyType: keyType
            ) {
                isGenerating = false
                onSave(entry)
                dismiss()
            } else {
                isGenerating = false
            }
        }
    }

    private var generationError: String? {
        guard let failure = coordinator.failure(for: .generateKey) else {
            return nil
        }
        return SSHKeySettingsFailurePresentation.message(
            for: .generateKey,
            failure: failure
        )
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
        .adaptiveSoftScrollEdges()
    }

    private func copyToClipboard(_ text: String) {
        Clipboard.copy(text)
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
        .adaptiveSoftScrollEdges()
    }

    private func copyToClipboard(_ text: String) {
        Clipboard.copy(text)
        copied = true
    }
}

// MARK: - Preview

#if DEBUG
    #Preview {
        KeychainSettingsView()
            .environmentObject(SSHKeySettingsCoordinator.preview)
    }
#endif
