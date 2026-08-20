import AVKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RemoteFileInspectorView: View {
    enum Chrome {
        case sidebar
        case sheet
    }

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case metadata
        case content

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .metadata:
                return "Metadata"
            case .content:
                return "Preview"
            }
        }
    }

    let selectedEntry: RemoteFileEntry?
    let viewerPayload: RemoteFileViewerPayload?
    let isLoadingViewer: Bool
    let viewerError: RemoteFileBrowserError?
    let directoryError: RemoteFileBrowserError?
    let chrome: Chrome
    let backgroundColor: Color
    let previewBackgroundColor: Color
    let sectionBackgroundColor: Color
    let onLoadPreview: ((RemoteFileEntry) -> Void)?
    let onDownloadPreview: ((RemoteFileEntry) -> Void)?
    let onDownload: ((RemoteFileEntry) -> Void)?
    let onShare: ((RemoteFileEntry) -> Void)?
    let onRename: ((RemoteFileEntry) -> Void)?
    let onMove: ((RemoteFileEntry) -> Void)?
    let onEditPermissions: ((RemoteFileEntry) -> Void)?
    let onDelete: ((RemoteFileEntry) -> Void)?
    let onClose: (() -> Void)?
    let onSaveText: ((RemoteFileEntry, String) async throws -> Void)?

    @State private var selectedTab: InspectorTab = .metadata
    @State private var editableText = ""
    @State private var isEditingText = false
    @State private var isSavingText = false
    @State private var textSaveErrorMessage: String?
    @State private var presentedMediaPreview: PresentedMediaPreview?

    var body: some View {
        Group {
            if chrome == .sidebar {
                sidebarInspectorContent
            } else {
                sheetInspectorContent
            }
        }
        .background(backgroundColor)
        .onChange(of: selectedEntry?.path) { _ in
            selectedTab = .metadata
            isEditingText = false
            isSavingText = false
            textSaveErrorMessage = nil
            editableText = viewerPayload?.textPreview ?? ""
        }
        .onChange(of: selectedEntry?.supportsPreview) { supportsPreview in
            if supportsPreview != true {
                selectedTab = .metadata
            }
        }
        .onChange(of: viewerPayload?.textPreview) { newValue in
            guard !isEditingText else { return }
            editableText = newValue ?? ""
        }
        .task(id: previewRequestID) {
            guard activeTab == .content, let selectedEntry, selectedEntry.supportsPreview else { return }
            guard viewerPayload?.entry.path != selectedEntry.path else { return }
            guard !isLoadingViewer else { return }
            guard viewerError == nil else { return }
            onLoadPreview?(selectedEntry)
        }
        .alert(String(localized: "Unable to Save"), isPresented: textSaveErrorBinding) {
            Button(String(localized: "OK"), role: .cancel) {
                textSaveErrorMessage = nil
            }
        } message: {
            Text(textSaveErrorMessage ?? "")
        }
        .sheet(item: $presentedMediaPreview) { item in
            RemoteFileExpandedMediaPreview(item: item)
                .adaptiveSoftScrollEdges()
        }
    }

    @ViewBuilder
    private var sidebarInspectorContent: some View {
        if let selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: chrome == .sidebar ? 12 : 16) {
                    inspectorHeader(for: selectedEntry)
                    if showsPreviewTab {
                        inspectorTabs
                    }
                }
                .padding(chrome == .sidebar ? 12 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)

                if activeTab == .metadata {
                    Form {
                        metadataFormSection(for: selectedEntry)
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .background(backgroundColor)
                } else {
                    ScrollView {
                        previewContent(for: selectedEntry)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if chrome == .sidebar, onClose != nil {
                        HStack {
                            Spacer(minLength: 0)
                            closeInspectorButton
                        }
                    }

                    if let directoryError {
                        RemoteFileEmptyState(
                            icon: "exclamationmark.triangle.fill",
                            title: String(localized: "Preview Unavailable"),
                            message: directoryError.errorDescription ?? directoryError.localizedDescription
                        )
                    } else {
                        RemoteFileEmptyState(
                            icon: "doc.text.magnifyingglass",
                            title: String(localized: "Select an Item"),
                            message: String(localized: "Choose a file or folder to inspect its metadata.")
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sheetInspectorContent: some View {
        VStack(spacing: 0) {
            if selectedEntry != nil, showsPreviewTab {
                inspectorTabs
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }

            Form {
                if let selectedEntry {
                    if activeTab == .metadata {
                        metadataFormSection(for: selectedEntry)

                        if showsPrimaryActions(for: selectedEntry) {
                            primaryActionsFormSection(for: selectedEntry)
                        }

                        if onDelete != nil {
                            deleteFormSection(for: selectedEntry)
                        }
                    } else {
                        previewFormSection(for: selectedEntry)
                    }
                } else if let directoryError {
                    Section {
                        inspectorStatusMessage(
                            title: String(localized: "Preview Unavailable"),
                            message: directoryError.errorDescription ?? directoryError.localizedDescription,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                } else {
                    Section {
                        inspectorStatusMessage(
                            title: String(localized: "Select an Item"),
                            message: String(localized: "Choose a file or folder to inspect its metadata."),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(backgroundColor)
        }
        .background(backgroundColor)
    }

    private var inspectorTabs: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .frame(height: 36)
                        .background(
                            selectedTab == tab ? Color.primary.opacity(0.18) : Color.clear,
                            in: Capsule(style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func previewContent(for selectedEntry: RemoteFileEntry) -> some View {
        if let viewerPayload, viewerPayload.entry.path == selectedEntry.path {
            loadedSidebarPreviewContent(viewerPayload, selectedEntry: selectedEntry)
        } else if isLoadingViewer {
            RemoteFileEmptyState(
                icon: "doc.text.magnifyingglass",
                title: String(localized: "Loading Preview"),
                message: String(localized: "Fetching the remote file contents.")
            )
        } else if let viewerError {
            VStack(alignment: .leading, spacing: 12) {
                RemoteFileEmptyState(
                    icon: "exclamationmark.triangle.fill",
                    title: String(localized: "Preview Unavailable"),
                    message: viewerError.errorDescription ?? viewerError.localizedDescription
                )

                if let onLoadPreview {
                    Button(String(localized: "Retry Preview")) {
                        onLoadPreview(selectedEntry)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        } else {
            RemoteFileEmptyState(
                icon: "doc.text.magnifyingglass",
                title: String(localized: "Loading Preview"),
                message: String(localized: "Fetching the remote file contents.")
            )
        }
    }

    @ViewBuilder
    private func loadedSidebarPreviewContent(
        _ payload: RemoteFileViewerPayload,
        selectedEntry: RemoteFileEntry
    ) -> some View {
        switch payload.previewKind {
        case .text:
            textPreviewSection(
                payload,
                selectedEntry: selectedEntry,
                useSectionBackground: true
            )
        case .image, .video:
            mediaPreviewSection(payload)
        case .unavailable:
            if payload.requiresExplicitDownload {
                previewDownloadPrompt(payload)
            } else {
                previewUnavailableState(payload)
            }
        }
    }

    private func textPreviewSection(
        _ payload: RemoteFileViewerPayload,
        selectedEntry: RemoteFileEntry,
        useSectionBackground: Bool,
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Text(String(localized: "Preview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if isEditingText {
                TextEditor(text: $editableText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(previewContainerBackground(useSectionBackground: useSectionBackground))
            } else {
                ScrollView(.vertical) {
                    Text(payload.textPreview ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                .padding(12)
                .background(previewContainerBackground(useSectionBackground: useSectionBackground))
            }

            if payload.canEditText, onSaveText != nil {
                textEditingControls(for: selectedEntry, originalText: payload.textPreview ?? "")
            }

            if payload.isTruncated {
                Text(String(localized: "Preview output was truncated to avoid loading large remote files."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func textEditingControls(for entry: RemoteFileEntry, originalText: String) -> some View {
        HStack(spacing: 10) {
            if isEditingText {
                Button(String(localized: "Cancel")) {
                    isEditingText = false
                    editableText = originalText
                }
                .buttonStyle(.bordered)

                Button(String(localized: "Save")) {
                    Task {
                        await saveEditedText(for: entry)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingText || editableText == originalText)
            } else {
                Button(String(localized: "Edit Text")) {
                    editableText = originalText
                    isEditingText = true
                }
                .buttonStyle(.bordered)
            }

            if isSavingText {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func mediaPreviewSection(
        _ payload: RemoteFileViewerPayload,
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Text(String(localized: "Preview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let previewFileURL = payload.previewFileURL {
                switch payload.previewKind {
                case .image:
                    Button {
                        presentMediaPreview(payload)
                    } label: {
                        RemoteFileImagePreview(url: previewFileURL, backgroundColor: previewBackground)
                    }
                    .buttonStyle(.plain)
                case .video:
                    RemoteFileVideoPreview(url: previewFileURL, backgroundColor: previewBackground)
                case .text, .unavailable:
                    EmptyView()
                }

                Button {
                    presentMediaPreview(payload)
                } label: {
                    Label(String(localized: "Open Full Preview"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
            } else {
                if payload.requiresExplicitDownload {
                    previewDownloadPrompt(payload)
                } else {
                    previewUnavailableState(payload)
                }
            }
        }
    }

    @ViewBuilder
    private func previewDownloadPrompt(_ payload: RemoteFileViewerPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteFileEmptyState(
                icon: "arrow.down.circle",
                title: String(localized: "Download Preview"),
                message: payload.unavailableMessage
                    ?? String(localized: "Download the remote file to generate an inline preview.")
            )

            if let onDownloadPreview {
                Button {
                    onDownloadPreview(payload.entry)
                } label: {
                    let sizeLabel = previewSizeLabel(for: payload)
                    if let sizeLabel {
                        Label(
                            String(
                                format: String(localized: "Download Preview (%@)"),
                                sizeLabel
                            ),
                            systemImage: "arrow.down.circle"
                        )
                    } else {
                        Label(String(localized: "Download Preview"), systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func previewUnavailableState(_ payload: RemoteFileViewerPayload) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                RemoteFileEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: String(localized: "Preview Unavailable"),
                    message: unavailablePreviewMessage(for: payload)
                )

                unavailablePreviewAction(payload)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder
    private func unavailablePreviewAction(_ payload: RemoteFileViewerPayload) -> some View {
        #if os(macOS)
        if let previewFileURL = payload.previewFileURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([previewFileURL])
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "finder")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        } else if canShare(payload.entry) {
            Button {
                onShare?(payload.entry)
            } label: {
                Label(String(localized: "Open in Another App"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        #else
        if canDownload(payload.entry) {
            Button {
                onDownload?(payload.entry)
            } label: {
                Label(String(localized: "Save to Files"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        #endif
    }

    private func unavailablePreviewMessage(for payload: RemoteFileViewerPayload) -> String {
        #if os(macOS)
        if payload.previewKind == .video, payload.previewFileURL != nil {
            return String(
                localized: "Inline video preview is unreliable for this downloaded file on macOS. Reveal it in Finder and open it with another app such as VLC or IINA."
            )
        }
        #endif

        if let message = payload.unavailableMessage {
            if message == String(localized: "This file downloaded successfully, but macOS could not open it for inline preview.") {
                return String(
                    localized: "This file downloaded successfully, but macOS could not decode it for inline preview. Reveal it in Finder and open it with another app such as VLC or IINA."
                )
            }
            return message
        }

        return String(localized: "Inline preview is unavailable for this file.")
    }

    private func previewContainerBackground(useSectionBackground: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(useSectionBackground ? previewBackground : Color.clear)
    }

    private func metadataSection(for entry: RemoteFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Information"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                metadataRow(String(localized: "Name"), value: entry.name)
                metadataDivider
                metadataRow(String(localized: "Kind"), value: kindLabel(for: entry))
                metadataDivider
                metadataRow(String(localized: "Location"), value: entry.path)
                metadataDivider
                metadataRow(String(localized: "Size"), value: sizeLabel(for: entry))
                metadataDivider
                metadataRow(String(localized: "Modified"), value: modifiedLabel(for: entry))

                if let permissions = entry.formattedPermissions {
                    metadataDivider
                    metadataRow(String(localized: "Permissions"), value: permissions)
                }

                if let target = entry.symlinkTarget {
                    metadataDivider
                    metadataRow(String(localized: "Symlink"), value: target)
                }
            }

            if showsPrimaryActions(for: entry) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Actions"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        if canDownload(entry) {
                            inspectorActionButton(
                                title: String(localized: "Download…"),
                                systemImage: "arrow.down.circle"
                            ) {
                                onDownload?(entry)
                            }
                        }

                        if onRename != nil {
                            inspectorActionButton(
                                title: String(localized: "Rename…"),
                                systemImage: "pencil"
                            ) {
                                onRename?(entry)
                            }
                        }

                        if onMove != nil {
                            inspectorActionButton(
                                title: String(localized: "Move…"),
                                systemImage: "arrow.right.circle"
                            ) {
                                onMove?(entry)
                            }
                        }

                        if canEditPermissions(entry) {
                            inspectorActionButton(
                                title: String(localized: "Permissions…"),
                                systemImage: "lock.shield"
                            ) {
                                onEditPermissions?(entry)
                            }
                        }
                    }
                }
            }

            if onDelete != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Remove"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    inspectorActionButton(
                        title: String(localized: "Delete"),
                        systemImage: "trash",
                        tint: .red
                    ) {
                        onDelete?(entry)
                    }
                }
            }
        }
    }

    private func metadataFormSection(for entry: RemoteFileEntry) -> some View {
        Section(String(localized: "Information")) {
            metadataFormRow(String(localized: "Name"), value: entry.name)
            metadataFormRow(String(localized: "Kind"), value: kindLabel(for: entry))
            metadataFormMultilineRow(String(localized: "Location"), value: entry.path)
            metadataFormRow(String(localized: "Size"), value: sizeLabel(for: entry))
            metadataFormRow(String(localized: "Modified"), value: modifiedLabel(for: entry))

            if let permissions = entry.formattedPermissions {
                metadataFormRow(String(localized: "Permissions"), value: permissions)
            }

            if let target = entry.symlinkTarget {
                metadataFormMultilineRow(String(localized: "Symlink"), value: target)
            }
        }
    }

    private func primaryActionsFormSection(for entry: RemoteFileEntry) -> some View {
        Section(String(localized: "Actions")) {
            if canDownload(entry) {
                Button {
                    onDownload?(entry)
                } label: {
                    Label(String(localized: "Download"), systemImage: "arrow.down.circle")
                }
            }

            if canShare(entry) {
                Button {
                    onShare?(entry)
                } label: {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
            }

            if onRename != nil {
                Button {
                    onRename?(entry)
                } label: {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
            }

            if onMove != nil {
                Button {
                    onMove?(entry)
                } label: {
                    Label(String(localized: "Move"), systemImage: "arrow.right.circle")
                }
            }

            if canEditPermissions(entry) {
                Button {
                    onEditPermissions?(entry)
                } label: {
                    Label(String(localized: "Permissions"), systemImage: "lock.shield")
                }
            }
        }
    }

    private func deleteFormSection(for entry: RemoteFileEntry) -> some View {
        Section {
            Button(role: .destructive) {
                onDelete?(entry)
            } label: {
                Label {
                    Text(String(localized: "Delete"))
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func inspectorHeader(for entry: RemoteFileEntry) -> some View {
        HStack(alignment: .top, spacing: chrome == .sidebar ? 12 : 14) {
            RoundedRectangle(cornerRadius: inspectorHeaderIconCornerRadius, style: .continuous)
                .fill(sectionBackground)
                .frame(width: inspectorHeaderIconSize, height: inspectorHeaderIconSize)
                .overlay {
                    Image(systemName: entry.iconName)
                        .font(.system(size: inspectorHeaderSymbolSize, weight: .medium))
                        .foregroundStyle(inspectorIconTint(for: entry))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(inspectorHeaderTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(inspectorSubtitle(for: entry))
                    .font(inspectorHeaderSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if chrome == .sidebar {
                HStack(spacing: 6) {
                    Menu {
                        sidebarInspectorActionMenu(for: entry)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text("File Actions"))

                    if onClose != nil {
                        closeInspectorButton
                    }
                }
            }
        }
    }

    private var closeInspectorButton: some View {
        Button {
            onClose?()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help(Text("Close Preview"))
    }

    @ViewBuilder
    private func sidebarInspectorActionMenu(for entry: RemoteFileEntry) -> some View {
        if canDownload(entry) {
            Button {
                onDownload?(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }
        }

        if canShare(entry) {
            Button {
                onShare?(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }
        }

        if canDownload(entry) || canShare(entry) {
            Divider()
        }

        if canEditPermissions(entry) {
            Button {
                onEditPermissions?(entry)
            } label: {
                Label(String(localized: "Permissions…"), systemImage: "lock.shield")
            }
        }

        if onRename != nil {
            Button {
                onRename?(entry)
            } label: {
                Label(String(localized: "Rename…"), systemImage: "pencil")
            }
        }

        if onMove != nil {
            Button {
                onMove?(entry)
            } label: {
                Label(String(localized: "Move…"), systemImage: "arrow.right.circle")
            }
        }

        Divider()

        Button {
            Clipboard.copy(entry.name)
        } label: {
            Label(String(localized: "Copy Name"), systemImage: "textformat")
        }

        Button {
            Clipboard.copy(entry.path)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }

        if onDelete != nil {
            Divider()

            Button(role: .destructive) {
                onDelete?(entry)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }

    private func inspectorSubtitle(for entry: RemoteFileEntry) -> String {
        let kind = kindLabel(for: entry)
        let size = sizeLabel(for: entry)
        guard size != "—" else { return kind }
        return "\(kind) - \(size)"
    }

    private func metadataFormRow(_ key: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .textSelection(.enabled)
        } label: {
            Text(key)
        }
    }

    private func metadataFormMultilineRow(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key)
                .foregroundStyle(.primary)

            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func previewFormSection(for selectedEntry: RemoteFileEntry) -> some View {
        Section {
            if let viewerPayload, viewerPayload.entry.path == selectedEntry.path {
                switch viewerPayload.previewKind {
                case .text:
                    textPreviewSection(
                        viewerPayload,
                        selectedEntry: selectedEntry,
                        useSectionBackground: false,
                        showsHeader: false
                    )
                case .image, .video:
                    mediaPreviewSection(viewerPayload, showsHeader: false)
                case .unavailable:
                    if viewerPayload.requiresExplicitDownload {
                        previewDownloadPrompt(viewerPayload)
                    } else {
                        inspectorStatusMessage(
                            title: String(localized: "Preview Unavailable"),
                            message: viewerPayload.unavailableMessage
                                ?? String(localized: "Inline preview is unavailable for this file."),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            } else if isLoadingViewer {
                inspectorLoadingMessage(
                    title: String(localized: "Loading Preview"),
                    message: String(localized: "Fetching the remote file contents.")
                )
            } else if let viewerError {
                inspectorStatusMessage(
                    title: String(localized: "Preview Unavailable"),
                    message: viewerError.errorDescription ?? viewerError.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )

                if let onLoadPreview {
                    Button(String(localized: "Retry Preview")) {
                        onLoadPreview(selectedEntry)
                    }
                }
            } else {
                inspectorLoadingMessage(
                    title: String(localized: "Loading Preview"),
                    message: String(localized: "Fetching the remote file contents.")
                )
            }
        } header: {
            Text(String(localized: "Preview"))
        }
    }

    private var textSaveErrorBinding: Binding<Bool> {
        Binding(
            get: { textSaveErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    textSaveErrorMessage = nil
                }
            }
        )
    }

    private func saveEditedText(for entry: RemoteFileEntry) async {
        guard let onSaveText else { return }

        isSavingText = true
        do {
            try await onSaveText(entry, editableText)
            isEditingText = false
            textSaveErrorMessage = nil
        } catch {
            textSaveErrorMessage = error.localizedDescription
        }
        isSavingText = false
    }

    private func inspectorStatusMessage(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func inspectorLoadingMessage(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func inspectorIconTint(for entry: RemoteFileEntry) -> Color {
        switch entry.type {
        case .directory:
            return .accentColor
        case .symlink:
            return .secondary
        case .other:
            return .secondary
        case .file:
            return .primary
        }
    }

    private func metadataRow(_ key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(key)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: metadataLabelWidth, alignment: .leading)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
    }

    private func inspectorActionButton(
        title: String,
        systemImage: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 18)

                Text(title)
                    .font(.body.weight(.semibold))

                Spacer(minLength: 12)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(sectionBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private var metadataDivider: some View {
        Divider()
    }

    private func canDownload(_ entry: RemoteFileEntry) -> Bool {
        entry.type != .directory && onDownload != nil
    }

    private var inspectorHeaderIconSize: CGFloat {
        chrome == .sidebar ? 36 : 56
    }

    private var inspectorHeaderIconCornerRadius: CGFloat {
        chrome == .sidebar ? 9 : 14
    }

    private var inspectorHeaderSymbolSize: CGFloat {
        chrome == .sidebar ? 17 : 26
    }

    private var inspectorHeaderTitleFont: Font {
        chrome == .sidebar ? .headline.weight(.semibold) : .title2.weight(.semibold)
    }

    private var inspectorHeaderSubtitleFont: Font {
        chrome == .sidebar ? .subheadline : .title3
    }

    private func canShare(_ entry: RemoteFileEntry) -> Bool {
        entry.type != .directory && onShare != nil
    }

    private func canEditPermissions(_ entry: RemoteFileEntry) -> Bool {
        guard onEditPermissions != nil, entry.permissions != nil else { return false }
        return entry.type != .symlink
    }

    private func showsPrimaryActions(for entry: RemoteFileEntry) -> Bool {
        canDownload(entry) || canShare(entry) || onRename != nil || onMove != nil || canEditPermissions(entry)
    }

    private func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return RemoteFileByteCountFormatter.string(from: size)
    }

    private func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            return entry.metadataTypeLabel == RemoteFileType.file.displayName
                ? String(localized: "Document")
                : entry.metadataTypeLabel
        }
    }

    private var previewBackground: Color {
        previewBackgroundColor
    }

    private var sectionBackground: Color {
        sectionBackgroundColor
    }

    private var metadataLabelWidth: CGFloat {
        chrome == .sidebar ? 108 : 120
    }

    private var showsPreviewTab: Bool {
        selectedEntry?.supportsPreview == true
    }

    private var activeTab: InspectorTab {
        showsPreviewTab ? selectedTab : .metadata
    }

    private var previewRequestID: String {
        guard activeTab == .content, let selectedEntry else { return "metadata" }
        return selectedEntry.path
    }

    private func previewSizeLabel(for payload: RemoteFileViewerPayload) -> String? {
        guard let byteCount = payload.previewByteCount else { return nil }
        return RemoteFileByteCountFormatter.string(from: byteCount)
    }

    private func presentMediaPreview(_ payload: RemoteFileViewerPayload) {
        guard let url = payload.previewFileURL else { return }
        presentedMediaPreview = PresentedMediaPreview(
            title: payload.entry.name,
            kind: payload.previewKind,
            url: url
        )
    }
}

private struct PresentedMediaPreview: Identifiable {
    let title: String
    let kind: RemoteFilePreviewKind
    let url: URL

    var id: String { url.absoluteString }
}

private struct RemoteFileImagePreview: View {
    let url: URL
    let backgroundColor: Color

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
                    .padding(12)
                    .background(previewBackground)
            } else {
                RemoteFileEmptyState(
                    icon: "photo",
                    title: String(localized: "Preview Unavailable"),
                    message: String(localized: "The image data could not be rendered.")
                )
            }
        }
    }

    #if os(macOS)
    private var image: Image? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }
    #else
    private var image: Image? {
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }
    #endif

    private var previewBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(backgroundColor)
    }
}

private struct RemoteFileVideoPreview: View {
    let url: URL
    let backgroundColor: Color

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct RemoteFileExpandedMediaPreview: View {
    let item: PresentedMediaPreview

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        #if os(iOS)
        NavigationStack {
            mediaContent
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) {
                            dismiss()
                        }
                    }
                }
        }
        .adaptiveSoftScrollEdges()
        #else
        VStack(spacing: 0) {
            HStack {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(String(localized: "Close")) {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            mediaContent
        }
        .frame(minWidth: 700, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var mediaContent: some View {
        ZStack {
            Color.black.opacity(0.96)
                .ignoresSafeArea()

            switch item.kind {
            case .image:
                imageContent
            case .video:
                videoContent
            case .text, .unavailable:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: item.url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        } else {
            RemoteFileEmptyState(
                icon: "photo",
                title: String(localized: "Preview Unavailable"),
                message: String(localized: "The image data could not be rendered.")
            )
        }
        #else
        if let image = UIImage(contentsOfFile: item.url.path) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        } else {
            RemoteFileEmptyState(
                icon: "photo",
                title: String(localized: "Preview Unavailable"),
                message: String(localized: "The image data could not be rendered.")
            )
        }
        #endif
    }

    private var videoContent: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.url) {
            player?.pause()
            player = AVPlayer(url: item.url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}
