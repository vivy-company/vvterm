import SwiftUI

private struct RemoteFileSheetActionLabel: View {
    let title: String
    let isSubmitting: Bool

    var body: some View {
        Text(title)
            .opacity(isSubmitting ? 0 : 1)
            .overlay {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }
}

struct RemoteFileRenameSheet: View {
    let entry: RemoteFileEntry
    @Binding var proposedName: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onRename: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            renameContent
                .navigationTitle(String(localized: "Rename"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetDismissButton(title: "Cancel", action: onCancel)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        SheetConfirmationButton(title: "Rename", isWorking: isSubmitting, action: onRename)
                        .disabled(trimmedProposedName.isEmpty || isSubmitting)
                    }
                }
        }
        .adaptiveSoftScrollEdges()
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Rename"))
                .font(.title2.weight(.semibold))

            renameContent

            HStack {
                Spacer()

                SheetDismissButton(title: "Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

                Button {
                    onRename()
                } label: {
                    RemoteFileSheetActionLabel(
                        title: String(localized: "Rename"),
                        isSubmitting: isSubmitting
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedProposedName.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        #endif
    }

    private var renameContent: some View {
        Form {
            Section(String(localized: "Item")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name)
                        .font(.headline)

                    Text(entry.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "New Name")) {
                TextField(String(localized: "Name"), text: $proposedName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var trimmedProposedName: String {
        proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RemoteFileCreateFolderSheet: View {
    let destinationPath: String
    @Binding var folderName: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            createFolderContent
                .navigationTitle(String(localized: "New Folder"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetDismissButton(title: "Cancel", action: onCancel)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        SheetConfirmationButton(title: "Create", isWorking: isSubmitting, action: onCreate)
                        .disabled(trimmedFolderName.isEmpty || isSubmitting)
                    }
                }
        }
        .adaptiveSoftScrollEdges()
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "New Folder"))
                .font(.title2.weight(.semibold))

            createFolderContent

            HStack {
                Spacer()

                SheetDismissButton(title: "Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

                Button {
                    onCreate()
                } label: {
                    RemoteFileSheetActionLabel(
                        title: String(localized: "Create"),
                        isSubmitting: isSubmitting
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedFolderName.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        #endif
    }

    private var createFolderContent: some View {
        Form {
            Section(String(localized: "Destination")) {
                Text(destinationPath)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.vertical, 4)
            }

            Section(String(localized: "Folder Name")) {
                TextField(String(localized: "Name"), text: $folderName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var trimmedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RemoteFileMoveSheet: View {
    let entry: RemoteFileEntry
    @Binding var destinationDirectory: String
    let onLoadDirectories: (String) async throws -> [RemoteFileEntry]
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onMove: () -> Void

    @State private var currentDirectory: String
    @State private var directories: [RemoteFileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        entry: RemoteFileEntry,
        destinationDirectory: Binding<String>,
        onLoadDirectories: @escaping (String) async throws -> [RemoteFileEntry],
        isSubmitting: Bool,
        onCancel: @escaping () -> Void,
        onMove: @escaping () -> Void
    ) {
        self.entry = entry
        _destinationDirectory = destinationDirectory
        self.onLoadDirectories = onLoadDirectories
        self.isSubmitting = isSubmitting
        self.onCancel = onCancel
        self.onMove = onMove
        _currentDirectory = State(initialValue: destinationDirectory.wrappedValue)
    }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationStack {
                moveContent
                    .navigationTitle(String(localized: "Move"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SheetDismissButton(title: "Cancel", action: onCancel)
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            SheetConfirmationButton(title: "Move", isWorking: isSubmitting, action: onMove)
                            .disabled(destinationDirectory.isEmpty || isSubmitting)
                        }
                    }
            }
            #else
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "Move"))
                    .font(.title2.weight(.semibold))

                moveContent

                HStack {
                    Spacer()

                    SheetDismissButton(title: "Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                    Button {
                        onMove()
                    } label: {
                        RemoteFileSheetActionLabel(
                            title: String(localized: "Move"),
                            isSubmitting: isSubmitting
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destinationDirectory.isEmpty || isSubmitting)
                }
            }
            .padding(20)
            #endif
        }
        .task(id: currentDirectory) {
            await loadDirectories()
        }
        .adaptiveSoftScrollEdges()
    }

    private var moveContent: some View {
        Form {
            Section(String(localized: "Item")) {
                HStack(spacing: 12) {
                    Image(systemName: entry.iconName)
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.headline)
                            .lineLimit(2)

                        Text(entry.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "Selected Folder")) {
                selectedDestinationRow
            }

            Section(String(localized: "Choose Folder")) {
                if currentDirectory != "/" {
                    Button {
                        navigate(to: RemoteFilePath.parent(of: currentDirectory))
                    } label: {
                        pickerRow(
                            title: String(localized: "Up"),
                            systemImage: "arrow.up",
                            iconColor: .accentColor
                        )
                    }
                }

                Button {
                    navigate(to: "/")
                } label: {
                    pickerRow(
                        title: String(localized: "Root"),
                        systemImage: "externaldrive",
                        iconColor: .accentColor
                    )
                }

                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "Loading folders…"))
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button(String(localized: "Retry")) {
                            Task { await loadDirectories() }
                        }
                    }
                } else if directories.isEmpty {
                    Text(String(localized: "No subfolders in this location."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(directories.enumerated()), id: \.element.id) { _, directory in
                        Button {
                            navigate(to: directory.path)
                        } label: {
                            pickerRow(
                                title: directory.name,
                                systemImage: "folder",
                                iconColor: .accentColor,
                                showsCheckmark: currentDirectory == directory.path
                            )
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var selectedDestinationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.checkmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(folderDisplayName(for: destinationDirectory))
                    .font(.headline)
                    .lineLimit(1)

                Text(destinationDirectory)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func pickerRow(
        title: String,
        systemImage: String,
        iconColor: Color,
        showsCheckmark: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)

            Text(title)
                .foregroundStyle(.primary)

            Spacer()

            if showsCheckmark {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @MainActor
    private func loadDirectories() async {
        isLoading = true
        errorMessage = nil
        do {
            directories = try await onLoadDirectories(currentDirectory)
        } catch {
            directories = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func navigate(to path: String) {
        let normalizedPath = RemoteFilePath.normalize(path)
        currentDirectory = normalizedPath
        destinationDirectory = normalizedPath
    }

    private func folderDisplayName(for path: String) -> String {
        let normalizedPath = RemoteFilePath.normalize(path)
        guard normalizedPath != "/" else { return String(localized: "Root") }
        return URL(fileURLWithPath: normalizedPath).lastPathComponent
    }
}

struct RemoteFileDeleteConfirmationSheet: View {
    let entry: RemoteFileEntry
    let message: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle(String(localized: "Delete"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetDismissButton(title: "Cancel", action: onCancel)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Delete"), role: .destructive) {
                            onDelete()
                        }
                    }
                }
        }
        .adaptiveSoftScrollEdges()
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Delete"))
                .font(.title2.weight(.semibold))

            content

            HStack {
                Spacer()

                SheetDismissButton(title: "Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Delete"), role: .destructive) {
                    onDelete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #endif
    }

    private var content: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "trash.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(.headline)

                        Text(entry.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }
}

struct RemoteFilePermissionEditorSheet: View {
    let entry: RemoteFileEntry
    @Binding var draft: RemoteFilePermissionDraft
    let originalAccessBits: UInt32
    let preservedBits: UInt32
    let errorMessage: String?
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onApply: () -> Void

    private var permissionsChanged: Bool {
        draft.accessBits != originalAccessBits
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(String(localized: "Permissions"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetDismissButton(title: "Cancel", action: onCancel)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        SheetConfirmationButton(title: "Apply", isWorking: isSubmitting, action: onApply)
                        .disabled(!permissionsChanged || isSubmitting)
                    }
                }
        }
        .adaptiveSoftScrollEdges()
        #else
        VStack(spacing: 0) {
            content

            Divider()

            HStack {
                SheetDismissButton(title: "Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onApply()
                } label: {
                    RemoteFileSheetActionLabel(
                        title: String(localized: "Apply"),
                        isSubmitting: isSubmitting
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!permissionsChanged || isSubmitting)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                summaryCard

                ForEach(RemoteFilePermissionAudience.allCases) { audience in
                    permissionGroup(for: audience)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    inlineErrorMessage(errorMessage)
                }

                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isSubmitting)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.name, systemImage: entry.iconName)
                .font(.headline)

            Text(entry.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Access Summary"))
                .font(.subheadline.weight(.semibold))

            ForEach(RemoteFilePermissionAudience.allCases) { audience in
                HStack(alignment: .top, spacing: 10) {
                    Text(audienceTitle(audience))
                        .font(.callout.weight(.medium))
                        .frame(width: 86, alignment: .leading)

                    Text(accessSummary(for: audience))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Mode \(summaryModeString)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.18))
        )
    }

    private func permissionGroup(for audience: RemoteFilePermissionAudience) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(audienceTitle(audience))
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(RemoteFilePermissionCapability.allCases) { capability in
                    Toggle(isOn: permissionBinding(for: capability, audience: audience)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capabilityTitle(capability))
                                .font(.body.weight(.medium))

                            Text(capabilityDescription(capability))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    if capability != .execute {
                        Divider()
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.14))
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preservedBits != 0 {
                Text(String(localized: "Special permission bits already on this item will be preserved."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(footerDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func inlineErrorMessage(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.orange.opacity(0.12))
        )
    }

    private func permissionBinding(
        for capability: RemoteFilePermissionCapability,
        audience: RemoteFilePermissionAudience
    ) -> Binding<Bool> {
        Binding(
            get: {
                draft.isEnabled(capability, for: audience)
            },
            set: { isEnabled in
                draft.set(isEnabled, capability: capability, for: audience)
            }
        )
    }

    private func audienceTitle(_ audience: RemoteFilePermissionAudience) -> String {
        switch audience {
        case .owner:
            return String(localized: "Owner")
        case .group:
            return String(localized: "Group")
        case .everyone:
            return String(localized: "Everyone")
        }
    }

    private func capabilityTitle(_ capability: RemoteFilePermissionCapability) -> String {
        switch capability {
        case .read:
            return String(localized: "Read")
        case .write:
            return String(localized: "Write")
        case .execute:
            return entry.type == .directory
                ? String(localized: "Open Folder")
                : String(localized: "Run")
        }
    }

    private func capabilityDescription(_ capability: RemoteFilePermissionCapability) -> String {
        switch (entry.type, capability) {
        case (.directory, .read):
            return String(localized: "See the names of items inside this folder.")
        case (.directory, .write):
            return String(localized: "Create, rename, or remove items inside this folder.")
        case (.directory, .execute):
            return String(localized: "Open this folder and access items inside it.")
        case (_, .read):
            return String(localized: "Open the file and read its contents.")
        case (_, .write):
            return String(localized: "Change or replace the file contents.")
        case (_, .execute):
            return String(localized: "Run this file as a program or script.")
        }
    }

    private func accessSummary(for audience: RemoteFilePermissionAudience) -> String {
        let granted = RemoteFilePermissionCapability.allCases.compactMap { capability -> String? in
            guard draft.isEnabled(capability, for: audience) else { return nil }
            return capabilityTitle(capability)
        }

        if granted.isEmpty {
            return String(localized: "No access")
        }

        return granted.joined(separator: ", ")
    }

    private var summaryModeString: String {
        let octal = String((preservedBits | draft.accessBits) & 0o7777, radix: 8)
        let padded = String(repeating: "0", count: max(0, 4 - octal.count)) + octal
        return "\(padded) (\(draft.symbolicSummary))"
    }

    private var footerDescription: String {
        if entry.type == .directory {
            return String(localized: "Folder permissions control who can view, change, and enter this folder.")
        }

        return String(localized: "File permissions control who can open, change, or run this file.")
    }
}
