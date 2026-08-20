import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import Combine

extension RemoteFileBrowserScreen {
    enum InlineEditor: Equatable {
        case createFolder(parentPath: String, proposedName: String, isSubmitting: Bool)
        case rename(entryPath: String, originalName: String, proposedName: String, isSubmitting: Bool)

        var proposedName: String {
            switch self {
            case .createFolder(_, let proposedName, _),
                 .rename(_, _, let proposedName, _):
                return proposedName
            }
        }

        var isSubmitting: Bool {
            switch self {
            case .createFolder(_, _, let isSubmitting),
                 .rename(_, _, _, let isSubmitting):
                return isSubmitting
            }
        }

        var createFolderParentPath: String? {
            guard case .createFolder(let parentPath, _, _) = self else { return nil }
            return parentPath
        }

        var renameEntryPath: String? {
            guard case .rename(let entryPath, _, _, _) = self else { return nil }
            return entryPath
        }
    }
}

@MainActor
final class RemoteFileBrowserPlatformState: ObservableObject {
    @Published var inlineEditor: RemoteFileBrowserScreen.InlineEditor?
    @Published var selectedPaths: Set<String> = []
    @Published var titlebarHeight: CGFloat = 0
}

extension RemoteFileBrowserScreen {
    @ViewBuilder
    func platformContent(_ snapshot: Snapshot) -> some View {
        browserContent(snapshot)
    }

    func platformSearchPresentation<Content: View>(_ content: Content) -> some View {
        content
    }

    func platformPresentation<Content: View>(_ content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if case .share(let item) = presentation {
                    RemoteFileSharePicker(item: item) {
                        finishSharing(item)
                    }
                    .frame(width: 1, height: 1)
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
            }
            .sheet(item: macOSSheetPresentationBinding, onDismiss: dismissPresentation) { route in
                macOSSheet(for: route)
                    .adaptiveSoftScrollEdges()
            }
    }

    var macOSSheetPresentationBinding: Binding<RemoteFileBrowserPresentation?> {
        Binding(
            get: {
                guard presentation?.isMacOSSheet == true else { return nil }
                return presentation
            },
            set: { route in
                if let route {
                    presentation = route
                } else if presentation?.isMacOSSheet == true {
                    dismissPresentation()
                }
            }
        )
    }

    @ViewBuilder
    func macOSSheet(for route: RemoteFileBrowserPresentation) -> some View {
        switch route {
        case .move(let draft):
            moveSheet(entry: draft.entry)
        case .permissions(let draft):
            permissionSheet(entry: draft.entry)
        default:
            EmptyView()
        }
    }

    func platformDropPresentation<Content: View>(_ content: Content, snapshot: Snapshot) -> some View {
        content
    }

    func platformCurrentPathDidChange() {
        cancelInlineEdit()
        platformState.selectedPaths.removeAll()
    }

    func platformSelectionTrackingPresentation<Content: View>(
        _ content: Content,
        snapshot: Snapshot
    ) -> some View {
        content
            .onChange(of: snapshot.entries.map(\.id)) { visiblePaths in
                let nextSelection = platformState.selectedPaths.intersection(Set(visiblePaths))
                if nextSelection != platformState.selectedPaths {
                    platformState.selectedPaths = nextSelection
                }

                if let inlineRenamePath = platformState.inlineEditor?.renameEntryPath,
                   !visiblePaths.contains(inlineRenamePath),
                   platformState.inlineEditor?.isSubmitting == false {
                    platformState.inlineEditor = nil
                }
            }
            .onChange(of: snapshot.selectedPath) { newValue in
                guard platformState.selectedPaths.count <= 1 else { return }

                guard let newValue, snapshot.entries.contains(where: { $0.id == newValue }) else {
                    if !platformState.selectedPaths.isEmpty {
                        platformState.selectedPaths = []
                    }
                    return
                }

                if platformState.selectedPaths != [newValue] {
                    platformState.selectedPaths = [newValue]
                }
            }
    }

    func platformRenameSheetSizing<Content: View>(_ content: Content) -> some View {
        content.frame(
            minWidth: 460,
            idealWidth: 500,
            maxWidth: 560,
            minHeight: 220,
            idealHeight: 240,
            maxHeight: 280
        )
    }

    func platformMoveSheetSizing<Content: View>(_ content: Content) -> some View {
        content.frame(
            minWidth: 460,
            idealWidth: 500,
            maxWidth: 560,
            minHeight: 420,
            idealHeight: 520,
            maxHeight: 620
        )
    }

    func platformPermissionSheetSizing<Content: View>(_ content: Content) -> some View {
        content.frame(
            minWidth: 460,
            idealWidth: 500,
            maxWidth: 560,
            minHeight: 520,
            idealHeight: 580,
            maxHeight: 680
        )
    }

    func platformTransferCompletionAction(fileURL: URL?) -> NoticeAction? {
        guard let fileURL else { return nil }

        return NoticeAction(id: "show-in-finder", title: String(localized: "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    func platformBeginUpload(to remotePath: String) {
        presentUploadPanel(for: remotePath)
    }

    func platformBeginDownload(_ entry: RemoteFileEntry) {
        presentDownloadPanel(for: entry)
    }

    func platformBeginCreateFolder(in remotePath: String) {
        beginInlineCreateFolder(in: remotePath)
    }

    func platformBeginRename(_ entry: RemoteFileEntry) {
        platformState.selectedPaths = [entry.id]
        browser.focus(entry, in: fileTab)
        platformState.inlineEditor = .rename(
            entryPath: entry.path,
            originalName: entry.name,
            proposedName: entry.name,
            isSubmitting: false
        )
    }

    func platformDidActivatePreviewEntry(_ entry: RemoteFileEntry) async {}

    func platformRequestDelete(_ entries: [RemoteFileEntry]) {
        presentDeleteConfirmation(for: entries)
    }

    func browserContent(_ snapshot: Snapshot) -> some View {
        GeometryReader { proxy in
            let splitMetrics = makeSplitMetrics(
                totalWidth: proxy.size.width,
                showsPreview: shouldShowPreview(snapshot)
            )

            VStack(spacing: 0) {
                if platformState.titlebarHeight > 0 {
                    Color.clear
                        .frame(height: platformState.titlebarHeight)
                }

                if splitMetrics.showsPreview {
                    HSplitView {
                        fileTable(snapshot)
                            .frame(minWidth: minimumTableWidth, maxWidth: .infinity, maxHeight: .infinity)

                        previewPanel(snapshot)
                            .frame(
                                minWidth: minimumPreviewWidth,
                                idealWidth: splitMetrics.previewIdealWidth,
                                maxWidth: splitMetrics.previewMaximumWidth,
                                maxHeight: .infinity
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fileTable(snapshot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                pathBar(snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .background {
                MacOSWindowTopInsetBridge(topInset: $platformState.titlebarHeight)
                    .frame(width: 0, height: 0)
            }
            .background(canvasColor)
            .contextMenu {
                browserActionMenu(currentPath: snapshot.currentPath)
            }
        }
    }

    func fileTable(_ snapshot: Snapshot) -> some View {
        MacOSRemoteFileTableView(
            entries: snapshot.entries,
            currentPath: snapshot.currentPath,
            selectedPaths: effectiveSelection(snapshot: snapshot, entries: snapshot.entries),
            sort: snapshot.sort,
            sortDirection: snapshot.sortDirection,
            inlineCreateFolderParentPath: platformState.inlineEditor?.createFolderParentPath,
            inlineRenamePath: platformState.inlineEditor?.renameEntryPath,
            inlineProposedName: platformState.inlineEditor?.proposedName ?? "",
            isInlineSubmitting: platformState.inlineEditor?.isSubmitting == true,
            onSelectionChange: { selection, modifierFlags in
                handleSelectionChange(selection, modifierFlags: modifierFlags, entries: snapshot.entries)
            },
            onActivate: { entry in
                previewEntry(entry)
            },
            onSortChange: { sort, direction in
                browser.updateSort(sort, direction: direction, for: fileTab)
            },
            onUploadDroppedURLs: { urls, destinationPath in
                handleDroppedURLs(urls, to: destinationPath)
            },
            onDropRemotePayload: { payload, destinationPath in
                handleDroppedRemotePayload(payload, to: destinationPath)
            },
            onBeginRemoteDrag: { payload in
                browser.beginDrag(payload)
            },
            onEndRemoteDrag: {
                browser.endDrag()
            },
            activeRemoteDragPayload: {
                browser.activeDragPayload
            },
            menuForEntry: { entry in
                appKitEntryMenu(for: entry)
            },
            menuForBackground: {
                appKitBackgroundMenu(currentPath: snapshot.currentPath)
            },
            exportEntry: { entry, destinationURL in
                try await browser.downloadItem(entry, to: destinationURL, server: server)
            },
            fileTypeIdentifier: { entry in
                RemoteFileItemProviderAdapter.fileTypeIdentifier(for: entry)
            },
            kindLabel: { entry in
                kindLabel(for: entry)
            },
            onSubmitInlineEdit: { proposedName in
                submitInlineEdit(proposedName)
            },
            onCancelInlineEdit: {
                cancelInlineEdit()
            },
            serverId: server.id
        )
        .background(canvasColor)
        .overlay {
            if let error = snapshot.directoryError {
                RemoteFileEmptyState(
                    icon: "exclamationmark.triangle.fill",
                    title: String(localized: "Browser Error"),
                    message: error.errorDescription ?? error.localizedDescription
                )
                .padding(32)
            }
        }
    }

    func beginInlineCreateFolder(in remotePath: String) {
        operationCoordinator.createUniqueFolder(
            in: remotePath,
            browser: browser,
            tab: fileTab,
            server: server,
            onSuccess: { createdPath, folderName in
                platformState.selectedPaths = [createdPath]
                browser.clearViewer(for: fileTab)
                platformState.inlineEditor = .rename(
                    entryPath: createdPath,
                    originalName: folderName,
                    proposedName: folderName,
                    isSubmitting: false
                )
            },
            onFailure: { error in
                presentOperationError(error)
            }
        )
    }

    func cancelInlineEdit() {
        guard platformState.inlineEditor?.isSubmitting != true else { return }
        platformState.inlineEditor = nil
    }

    func submitInlineEdit(_ proposedName: String) {
        guard let editor = platformState.inlineEditor, !editor.isSubmitting else { return }

        switch editor {
        case .createFolder(let parentPath, _, _):
            let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                platformState.inlineEditor = nil
                return
            }
            platformState.inlineEditor = .createFolder(
                parentPath: parentPath,
                proposedName: proposedName,
                isSubmitting: true
            )
            operationCoordinator.createFolder(
                named: proposedName,
                in: parentPath,
                browser: browser,
                tab: fileTab,
                server: server,
                onSuccess: { createdPath in
                    platformState.inlineEditor = nil
                    selectEntry(at: createdPath)
                },
                onFailure: { error in
                    platformState.inlineEditor = .createFolder(
                        parentPath: parentPath,
                        proposedName: proposedName,
                        isSubmitting: false
                    )
                    presentOperationError(error)
                }
            )

        case .rename(let entryPath, let originalName, _, _):
            guard let entry = browser.entries(for: fileTab).first(where: { $0.path == entryPath }) else {
                platformState.inlineEditor = nil
                return
            }
            platformState.inlineEditor = .rename(
                entryPath: entryPath,
                originalName: originalName,
                proposedName: proposedName,
                isSubmitting: true
            )
            operationCoordinator.rename(
                entry,
                to: proposedName,
                browser: browser,
                tab: fileTab,
                server: server,
                onSuccess: { destinationPath in
                    platformState.inlineEditor = nil
                    selectEntry(at: destinationPath)
                },
                onFailure: { error in
                    platformState.inlineEditor = .rename(
                        entryPath: entryPath,
                        originalName: originalName,
                        proposedName: proposedName,
                        isSubmitting: false
                    )
                    presentOperationError(error)
                }
            )
        }
    }

    func selectEntry(at path: String) {
        platformState.selectedPaths = [path]
        if let entry = browser.entries(for: fileTab).first(where: { $0.path == path }) {
            browser.focus(entry, in: fileTab)
        } else {
            browser.clearViewer(for: fileTab)
        }
    }

    func previewPanel(_ snapshot: Snapshot) -> some View {
        RemoteFileInspectorView(
            selectedEntry: snapshot.selectedEntry,
            viewerPayload: snapshot.viewerPayload,
            isLoadingViewer: snapshot.isLoadingViewer,
            viewerError: snapshot.viewerError,
            directoryError: snapshot.directoryError,
            chrome: .sidebar,
            backgroundColor: canvasColor,
            previewBackgroundColor: raisedSurfaceColor,
            sectionBackgroundColor: raisedSurfaceColor,
            onLoadPreview: { entry in
                Task { await browser.loadPreview(for: entry, in: fileTab, server: server) }
            },
            onDownloadPreview: { entry in
                Task {
                    await browser.loadPreview(for: entry, in: fileTab, server: server, allowLargeDownloads: true)
                }
            },
            onDownload: { entry in
                beginDownload(entry)
            },
            onShare: { entry in
                beginShare(entry)
            },
            onRename: { entry in
                beginRename(entry)
            },
            onMove: { entry in
                beginMove(entry)
            },
            onEditPermissions: { entry in
                guard canEditPermissions(for: entry) else { return }
                beginEditPermissions(entry)
            },
            onDelete: { entry in
                requestDelete([entry])
            },
            onClose: {
                browser.clearViewer(for: fileTab)
            },
            onSaveText: { entry, text in
                try await browser.saveTextPreview(text, for: entry, in: fileTab, server: server)
            }
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .background(canvasColor)
    }

    func shouldShowPreview(_ snapshot: Snapshot) -> Bool {
        snapshot.selectedEntry != nil || snapshot.viewerPayload != nil || snapshot.viewerError != nil || snapshot.isLoadingViewer
    }

    func pathBar(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    breadcrumbButton(
                        title: server.name,
                        systemImage: "server.rack",
                        isCurrent: snapshot.currentPath == "/"
                    ) {
                        Task {
                            await browser.openBreadcrumb(
                                .init(title: server.name, path: "/"),
                                in: fileTab,
                                server: server
                            )
                        }
                    }

                    ForEach(Array(snapshot.breadcrumbs.dropFirst().enumerated()), id: \.element.id) { index, breadcrumb in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)

                        breadcrumbButton(
                            title: breadcrumb.title,
                            systemImage: "folder.fill",
                            isCurrent: index == snapshot.breadcrumbs.dropFirst().count - 1
                        ) {
                            Task { await browser.openBreadcrumb(breadcrumb, in: fileTab, server: server) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }

            Divider()

            HStack {
                Spacer(minLength: 0)

                Text(footerStatusLabel(snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(chromeSurfaceColor)
    }

    func effectiveSelection(snapshot: Snapshot, entries: [RemoteFileEntry]) -> Set<String> {
        let visiblePaths = Set(entries.map(\.id))
        var selection = platformState.selectedPaths.intersection(visiblePaths)

        if selection.isEmpty,
           let selectedPath = snapshot.selectedPath,
           visiblePaths.contains(selectedPath) {
            selection = [selectedPath]
        }

        return selection
    }

    func selectedTableEntries(for snapshot: Snapshot) -> [RemoteFileEntry] {
        let selectedPaths = effectiveSelection(snapshot: snapshot, entries: snapshot.entries)
        guard !selectedPaths.isEmpty else { return [] }
        return snapshot.entries.filter { selectedPaths.contains($0.id) }
    }

    func handleSelectionChange(
        _ selection: Set<String>,
        modifierFlags: NSEvent.ModifierFlags,
        entries: [RemoteFileEntry]
    ) {
        platformState.selectedPaths = selection

        guard selection.count == 1,
              let selectedPath = selection.first,
              let entry = entries.first(where: { $0.id == selectedPath }) else {
            browser.clearViewer(for: fileTab)
            return
        }

        let selectionModifiers = modifierFlags.intersection([.command, .shift])
        guard selectionModifiers.isEmpty || selection.count == 1 else {
            browser.clearViewer(for: fileTab)
            return
        }

        browser.focus(entry, in: fileTab)
    }

    func handleDroppedURLs(_ urls: [URL], to destinationPath: String) {
        guard !urls.isEmpty else { return }
        beginUploadFlow(
            urls: urls,
            to: destinationPath,
            initialMessage: String(localized: "Preparing dropped files.")
        )
    }

    func handleDroppedRemotePayload(_ payload: RemoteFileDragPayload, to destinationPath: String) {
        operationCoordinator.transferDroppedItems(
            to: destinationPath,
            browser: browser,
            tab: fileTab,
            server: server
        ) {
            [payload]
        }
    }

    func presentUploadPanel(for remotePath: String) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Upload to Remote Folder")
        panel.message = String(localized: "Choose files or folders to upload.")
        panel.prompt = String(localized: "Upload")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        let response = panel.runModal()
        guard response == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        beginUploadFlow(
            urls: urls,
            to: remotePath,
            initialMessage: String(localized: "Preparing files for upload.")
        )
    }

    func presentDownloadPanel(for entry: RemoteFileEntry) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Download Remote File")
        panel.message = String(localized: "Choose where to save the downloaded file.")
        panel.nameFieldStringValue = entry.name.isEmpty ? "download" : entry.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = panel.runModal()
        guard response == .OK, let destinationURL = panel.url else { return }

        operationCoordinator.download(entry, to: destinationURL, browser: browser, server: server)
    }

    func presentDeleteConfirmation(for entries: [RemoteFileEntry]) {
        let sortedEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "trash", accessibilityDescription: String(localized: "Delete"))

        if sortedEntries.count == 1, let entry = sortedEntries.first {
            alert.messageText = deleteAlertTitle(for: entry)
            alert.informativeText = deleteAlertMessage(for: entry)
        } else {
            alert.messageText = String(
                format: String(localized: "Delete %lld Items?"),
                Int64(sortedEntries.count)
            )

            let previewNames = sortedEntries.prefix(3).map(\.name).joined(separator: ", ")
            if sortedEntries.count > 3 {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ and %lld more items from the remote server. This cannot be undone."),
                    previewNames,
                    Int64(sortedEntries.count - 3)
                )
            } else {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ from the remote server. This cannot be undone."),
                    previewNames
                )
            }
        }

        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        deleteEntries(sortedEntries)
    }

    func appKitBackgroundMenu(currentPath: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            makeMacOSMenuItem(
                title: String(localized: "Upload…"),
                systemImage: "square.and.arrow.up"
            ) {
                beginUpload(to: currentPath)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(
                title: String(localized: "New Folder"),
                systemImage: "folder.badge.plus"
            ) {
                beginCreateFolder(in: currentPath)
            }
        )
        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(
                title: String(localized: "Copy Path"),
                systemImage: "document.on.document"
            ) {
                Clipboard.copy(currentPath)
            }
        )
        return menu
    }

    func appKitEntryMenu(for entry: RemoteFileEntry) -> NSMenu {
        let targetEntries = contextMenuEntries(for: entry)
        if targetEntries.count > 1 {
            return appKitMultiEntryMenu(for: targetEntries)
        }

        let menu = NSMenu()

        switch entry.type {
        case .directory:
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Open"), systemImage: "folder") {
                    Task { await browser.openDirectory(entry, in: fileTab, server: server) }
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Upload…"), systemImage: "square.and.arrow.up") {
                    beginUpload(to: entry.path)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "New Folder"), systemImage: "folder.badge.plus") {
                    beginCreateFolder(in: entry.path)
                }
            )
            if canEditPermissions(for: entry) {
                menu.addItem(
                    makeMacOSMenuItem(title: String(localized: "Permissions…"), systemImage: "lock.shield") {
                        beginEditPermissions(entry)
                    }
                )
            }

        case .file, .other, .symlink:
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Open"), systemImage: "doc.text") {
                    previewEntry(entry)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Download…"), systemImage: "arrow.down.circle") {
                    beginDownload(entry)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Share…"), systemImage: "square.and.arrow.up") {
                    beginShare(entry)
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "Upload Here…"), systemImage: "square.and.arrow.up") {
                    beginUpload(to: RemoteFilePath.parent(of: entry.path))
                }
            )
            menu.addItem(
                makeMacOSMenuItem(title: String(localized: "New Folder Here"), systemImage: "folder.badge.plus") {
                    beginCreateFolder(in: RemoteFilePath.parent(of: entry.path))
                }
            )
            if canEditPermissions(for: entry) {
                menu.addItem(
                    makeMacOSMenuItem(title: String(localized: "Permissions…"), systemImage: "lock.shield") {
                        beginEditPermissions(entry)
                    }
                )
            }
        }

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Rename"), systemImage: "pencil") {
                beginRename(entry)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Move…"), systemImage: "arrow.right.circle") {
                beginMove(entry)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Delete"), systemImage: "trash") {
                requestDelete([entry])
            }
        )

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Name"), systemImage: "textformat") {
                Clipboard.copy(entry.name)
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Path"), systemImage: "document.on.document") {
                Clipboard.copy(entry.path)
            }
        )

        return menu
    }

    func contextMenuEntries(for entry: RemoteFileEntry) -> [RemoteFileEntry] {
        let selectedEntries = snapshot.entries.filter { platformState.selectedPaths.contains($0.id) }
        guard selectedEntries.count > 1,
              selectedEntries.contains(where: { $0.id == entry.id }) else {
            return [entry]
        }
        return selectedEntries
    }

    func appKitMultiEntryMenu(for entries: [RemoteFileEntry]) -> NSMenu {
        let sortedEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let menu = NSMenu()

        let title = String(
            format: String(localized: "%lld Selected"),
            Int64(sortedEntries.count)
        )
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Delete"), systemImage: "trash") {
                requestDelete(sortedEntries)
            }
        )

        menu.addItem(makeMacOSSeparatorMenuItem())
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Names"), systemImage: "textformat") {
                Clipboard.copy(sortedEntries.map(\.name).joined(separator: "\n"))
            }
        )
        menu.addItem(
            makeMacOSMenuItem(title: String(localized: "Copy Paths"), systemImage: "document.on.document") {
                Clipboard.copy(sortedEntries.map(\.path).joined(separator: "\n"))
            }
        )

        return menu
    }

    func footerStatusLabel(_ snapshot: Snapshot) -> String {
        let selectedEntries = selectedTableEntries(for: snapshot)
        var parts: [String] = []

        if selectedEntries.isEmpty {
            parts.append(itemCountLabel(for: snapshot.entries.count))
            if snapshot.isTruncated {
                parts.append(String(localized: "Listing truncated"))
            }
        } else {
            parts.append(selectionCountLabel(for: selectedEntries.count))
            if let totalBytes = totalSelectedBytes(for: selectedEntries) {
                parts.append(
                    String(
                        format: String(localized: "%@ total"),
                        RemoteFileByteCountFormatter.string(from: totalBytes)
                    )
                )
            }
        }

        if let availableBytes = snapshot.filesystemStatus?.availableBytes {
            parts.append(
                String(
                    format: String(localized: "%@ available"),
                    RemoteFileByteCountFormatter.string(from: availableBytes)
                )
            )
        }

        return parts.joined(separator: ", ")
    }

    func selectionCountLabel(for count: Int) -> String {
        count == 1
            ? String(localized: "1 selected")
            : String(format: String(localized: "%lld selected"), Int64(count))
    }

    func totalSelectedBytes(for entries: [RemoteFileEntry]) -> UInt64? {
        let fileSizes = entries.compactMap { entry -> UInt64? in
            guard entry.type != .directory else { return nil }
            return entry.size
        }
        guard !fileSizes.isEmpty else { return nil }

        var total: UInt64 = 0
        for size in fileSizes {
            let result = total.addingReportingOverflow(size)
            total = result.partialValue
            if result.overflow {
                return UInt64.max
            }
        }

        return total
    }

    func breadcrumbButton(
        title: String,
        systemImage: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(systemImage == "server.rack" ? Color.accentColor : folderTint)

                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    var folderTint: Color {
        Color(nsColor: .systemBlue)
    }

    var canvasColor: Color {
        terminalThemeBackgroundColor
    }

    var minimumPreviewWidth: CGFloat {
        220
    }

    var maximumPreviewWidth: CGFloat {
        440
    }

    var minimumTableWidth: CGFloat {
        220
    }

    func makeSplitMetrics(totalWidth: CGFloat, showsPreview: Bool) -> (showsPreview: Bool, previewIdealWidth: CGFloat, previewMaximumWidth: CGFloat) {
        guard showsPreview else {
            return (false, 0, 0)
        }

        let splitDividerAllowance: CGFloat = 12
        let availablePreviewWidth = totalWidth - minimumTableWidth - splitDividerAllowance

        guard availablePreviewWidth >= minimumPreviewWidth else {
            return (false, 0, 0)
        }

        let previewMaximumWidth = min(maximumPreviewWidth, availablePreviewWidth)
        let previewIdealWidth = min(
            previewMaximumWidth,
            max(minimumPreviewWidth, totalWidth * 0.34)
        )

        return (true, previewIdealWidth, previewMaximumWidth)
    }

    var chromeSurfaceColor: Color {
        surfaceColor(blendFraction: colorScheme == .dark ? 0.05 : 0.035)
    }

    var panelColor: Color {
        surfaceColor(blendFraction: colorScheme == .dark ? 0.09 : 0.06)
    }

    var raisedSurfaceColor: Color {
        surfaceColor(blendFraction: colorScheme == .dark ? 0.14 : 0.10)
    }

    func surfaceColor(blendFraction: CGFloat) -> Color {
        let baseColor = NSColor(terminalThemeBackgroundColor)
        let targetColor: NSColor = baseColor.brightnessComponent > 0.5 ? .black : .white
        return Color(baseColor.blended(withFraction: blendFraction, of: targetColor) ?? baseColor)
    }
}
#endif
