import SwiftUI
import UniformTypeIdentifiers

struct RemoteFileBrowserScreen: View {
    @ObservedObject var browser: RemoteFileBrowserStore
    @ObservedObject var operationCoordinator: RemoteFileOperationCoordinator
    let server: Server
    let fileTab: RemoteFileTab
    let appearance: TerminalAppearanceSnapshot
    let initialPath: String?
    let onCurrentPathChange: @MainActor (String?) -> Void

    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var appLockManager: AppLockManager
    @State var presentedPreviewPath: String?
    @State var presentation: RemoteFileBrowserPresentation?
    @State var isDropTargeted = false
    @StateObject var platformState = RemoteFileBrowserPlatformState()
    @StateObject var noticeHost = NoticeHostModel()

    struct Snapshot {
        let currentPath: String
        let breadcrumbs: [RemoteFileBreadcrumb]
        let entries: [RemoteFileEntry]
        let selectedEntry: RemoteFileEntry?
        let viewerPayload: RemoteFileViewerPayload?
        let directoryError: RemoteFileBrowserError?
        let viewerError: RemoteFileBrowserError?
        let isLoadingDirectory: Bool
        let isLoadingViewer: Bool
        let sort: RemoteFileSort
        let sortDirection: RemoteFileSortDirection
        let showHiddenFiles: Bool
        let isTruncated: Bool
        let selectedPath: String?
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    struct EmptyStateContent {
        let icon: String
        let title: String
        let message: String
    }

    init(
        browser: RemoteFileBrowserStore,
        server: Server,
        fileTab: RemoteFileTab,
        appearance: TerminalAppearanceSnapshot,
        initialPath: String? = nil,
        onCurrentPathChange: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.browser = browser
        self.server = server
        self.fileTab = fileTab
        self.appearance = appearance
        self.initialPath = initialPath
        self.onCurrentPathChange = onCurrentPathChange
        _operationCoordinator = ObservedObject(
            wrappedValue: browser.operationCoordinator(for: fileTab, server: server)
        )
    }

    var snapshot: Snapshot {
        let entries = browser.entries(for: fileTab)
        let viewerPayload = browser.viewerPayload(for: fileTab)
        let selectedPath = browser.selectedEntryPath(for: fileTab) ?? viewerPayload?.entry.path
        let selectedEntry = entries.first(where: { $0.path == selectedPath }) ?? viewerPayload?.entry

        return Snapshot(
            currentPath: browser.currentPath(for: fileTab),
            breadcrumbs: browser.breadcrumbs(for: fileTab),
            entries: entries,
            selectedEntry: selectedEntry,
            viewerPayload: viewerPayload,
            directoryError: browser.error(for: fileTab),
            viewerError: browser.viewerError(for: fileTab),
            isLoadingDirectory: browser.isLoading(for: fileTab),
            isLoadingViewer: browser.isLoadingViewer(for: fileTab),
            sort: browser.sort(for: fileTab),
            sortDirection: browser.sortDirection(for: fileTab),
            showHiddenFiles: browser.showHiddenFiles(for: fileTab),
            isTruncated: browser.isTruncated(for: fileTab),
            selectedPath: selectedPath,
            filesystemStatus: browser.filesystemStatus(for: fileTab)
        )
    }

    var initialLoadTaskID: String {
        "\(server.id.uuidString):\(fileTab.id.uuidString):\(initialPath ?? "")"
    }

    var remoteRowDropTypeIdentifiers: [String] {
        RemoteFileItemProviderAdapter.acceptedTypeIdentifiers
    }

    var terminalThemeBackgroundColor: Color {
        Color.fromHex(appearance.activeTheme.palette.backgroundHex)
    }

    @ViewBuilder
    func renameSheet(entry: RemoteFileEntry) -> some View {
        platformRenameSheetSizing(RemoteFileRenameSheet(
            entry: entry,
            proposedName: renameNameBinding,
            isSubmitting: isRenameSubmitting,
            onCancel: resetRenamePrompt,
            onRename: { renameEntry() }
        ))
    }

    func moveSheet(entry: RemoteFileEntry) -> some View {
        let fileBrowser = browser
        let fileServer = server

        return platformMoveSheetSizing(RemoteFileMoveSheet(
            entry: entry,
            destinationDirectory: moveDestinationBinding,
            onLoadDirectories: { path in
                try await fileBrowser.listDirectories(at: path, server: fileServer)
            },
            isSubmitting: isMoveSubmitting,
            onCancel: resetMovePrompt,
            onMove: moveEntry
        ))
    }

    @ViewBuilder
    func deleteSheet(entry: RemoteFileEntry) -> some View {
        RemoteFileDeleteConfirmationSheet(
            entry: entry,
            message: deleteAlertMessage(for: entry),
            onCancel: dismissPresentation,
            onDelete: deleteEntry
        )
    }

    @ViewBuilder
    func permissionSheet(entry: RemoteFileEntry) -> some View {
        platformPermissionSheetSizing(RemoteFilePermissionEditorSheet(
            entry: entry,
            draft: permissionDraftBinding,
            originalAccessBits: permissionOriginalAccessBits,
            preservedBits: permissionPreservedBits,
            errorMessage: permissionErrorMessage,
            isSubmitting: isPermissionSubmitting,
            onCancel: resetPermissionEditor,
            onApply: applyPermissions
        ))
    }

    var body: some View {
        let base = fileNoticeHost {
            ZStack {
                platformContent(snapshot)

                if isDropTargeted {
                    RemoteFileDropOverlay()
                        .padding(20)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: initialLoadTaskID) {
            await browser.loadInitialPath(for: server, tab: fileTab, initialPath: initialPath)
            presentDirectorySecurityApprovalIfNeeded()
        }
        .onAppear {
            onCurrentPathChange(browser.lastVisitedPath(for: fileTab))
        }

        let withDownloadExport = downloadExportPresentation(base)
        let withSearch = platformSearchPresentation(withDownloadExport)
        let withDrop = platformDropPresentation(withSearch, snapshot: snapshot)
        let withRoutes = platformPresentation(withDrop)
            .alert(item: alertPresentationBinding) { route in
                alert(for: route)
            }

        let withPathTracking = withRoutes
        .onChange(of: snapshot.currentPath) { newValue in
            onCurrentPathChange(newValue)
            if case .createFolder(let draft) = presentation,
               draft.destinationPath != newValue {
                resetNewFolderPrompt()
            }
            platformCurrentPathDidChange()
        }

        let withToolbarCommands = withPathTracking
        .onChange(of: browser.pendingToolbarCommand?.id) { _ in
            handlePendingToolbarCommand()
        }

        let withSecurityObservation = platformSelectionTrackingPresentation(
            withToolbarCommands,
            snapshot: snapshot
        )
            .onChange(of: snapshot.directoryError) { _ in
                presentDirectorySecurityApprovalIfNeeded()
            }
            .onChange(of: snapshot.viewerError) { _ in
                presentViewerSecurityApprovalIfNeeded()
            }

        securityApprovalPresentation(withSecurityObservation)
    }

    @ViewBuilder
    func fileNoticeHost<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NoticeHost(
            topBanner: noticeHost.topBanner,
            bottomOperations: noticeHost.bottomOperations + operationNotices,
            bottomInsetBehavior: .contentBottom
        ) {
            content()
        }
    }

    @ViewBuilder
    func downloadExportPresentation<Content: View>(_ content: Content) -> some View {
        if #available(iOS 17, macOS 14, *) {
            content.fileExporter(
                isPresented: downloadExporterBinding,
                document: downloadExportDocument,
                contentTypes: [.data],
                defaultFilename: downloadExportFilename,
                onCompletion: handleDownloadExportCompletion,
                onCancellation: handleDownloadExportCancellation
            )
        } else {
            content.fileExporter(
                isPresented: downloadExporterBinding,
                document: downloadExportDocument,
                contentType: .data,
                defaultFilename: downloadExportFilename,
                onCompletion: handleDownloadExportCompletion
            )
        }
    }

    var alertPresentationBinding: Binding<RemoteFileBrowserPresentation?> {
        Binding(
            get: {
                guard presentation?.isAlert == true else { return nil }
                return presentation
            },
            set: { route in
                if let route {
                    presentation = route
                } else if presentation?.isAlert == true {
                    dismissPresentation()
                }
            }
        )
    }

    func alert(for route: RemoteFileBrowserPresentation) -> Alert {
        switch route {
        case .operationError(let message):
            Alert(
                title: Text(String(localized: "Files")),
                message: Text(message),
                dismissButton: .cancel(Text(String(localized: "OK")), action: dismissPresentation)
            )
        case .transferCancellation(let request):
            Alert(
                title: Text(request.kind.confirmationTitle),
                message: Text(request.kind.confirmationMessage),
                primaryButton: .cancel(Text(request.kind.keepButtonTitle), action: dismissPresentation),
                secondaryButton: .destructive(Text(request.kind.cancelButtonTitle)) {
                    cancelTransfer(id: request.id)
                }
            )
        default:
            Alert(title: Text(String(localized: "Files")))
        }
    }

    var downloadExporterBinding: Binding<Bool> {
        Binding(
            get: { presentation?.isDownloadExport == true },
            set: { isPresented in
                if !isPresented, presentation?.isDownloadExport == true {
                    handleDownloadExportCancellation()
                }
            }
        )
    }

    var downloadExportDocument: RemoteFileDownloadDocument? {
        guard case .downloadExport(let export) = presentation else { return nil }
        return export.document
    }

    var downloadExportFilename: String {
        guard case .downloadExport(let export) = presentation else { return "" }
        return export.filename
    }

    func deleteAlertMessage(for entry: RemoteFileEntry) -> String {
        let itemName = entry.name.isEmpty ? entry.path : entry.name
        return String(
            format: String(localized: "This will permanently remove \"%@\" from the remote server. This cannot be undone."),
            itemName
        )
    }

    @MainActor
    func copyPathToClipboard(_ path: String) {
        Clipboard.copy(path)
        noticeHost.show(
            NoticeItem(
                id: UUID().uuidString,
                lane: .topBanner,
                level: .success,
                leading: .icon("checkmark.circle.fill"),
                message: String(localized: "Path copied to clipboard."),
                lifetime: .autoDismiss(.seconds(1.5))
            )
        )
    }

    func transferProgress(
        completedUnitCount: Int?,
        totalUnitCount: Int?
    ) -> NoticeProgress? {
        guard let completedUnitCount, let totalUnitCount else { return nil }
        return NoticeProgress(
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount
        )
    }

    func transferDetail(fileName: String?, filePath: String?) -> String? {
        if let filePath, !filePath.isEmpty {
            return filePath
        }

        if let fileName, !fileName.isEmpty {
            return fileName
        }

        return nil
    }

    func transferCompletionAction(fileURL: URL?) -> NoticeAction? {
        platformTransferCompletionAction(fileURL: fileURL)
    }

    var operationNotices: [NoticeItem] {
        operationCoordinator.operations.map { operation in
            let message: String
            let level: NoticeLevel
            let leading: NoticeLeading
            let progress: NoticeProgress?
            let dismissAction: (() -> Void)?

            switch operation.phase {
            case .running(let currentMessage, let completed, let total):
                message = currentMessage
                level = .info
                leading = .activity
                progress = transferProgress(
                    completedUnitCount: completed,
                    totalUnitCount: total
                )
                dismissAction = { requestTransferCancellation(id: operation.id) }
            case .awaitingSecurityApproval(let currentMessage):
                message = currentMessage
                level = .warning
                leading = .icon("lock.shield.fill")
                progress = nil
                dismissAction = { requestTransferCancellation(id: operation.id) }
            case .succeeded(let currentMessage):
                message = currentMessage
                level = .success
                leading = .icon("checkmark.circle.fill")
                progress = nil
                dismissAction = { operationCoordinator.dismiss(operation.id) }
            case .failed(let currentMessage):
                message = currentMessage
                level = .error
                leading = .icon("xmark.octagon.fill")
                progress = nil
                dismissAction = { operationCoordinator.dismiss(operation.id) }
            }

            return NoticeItem(
                id: operation.id.uuidString,
                lane: .bottomOperation,
                level: level,
                leading: leading,
                title: operation.title,
                message: message,
                detail: transferDetail(
                    fileName: operation.completion?.fileName,
                    filePath: operation.completion?.filePath
                ),
                progress: progress,
                action: transferCompletionAction(fileURL: operation.completion?.fileURL),
                dismissAction: dismissAction
            )
        }
    }

    @MainActor
    func requestTransferCancellation(id: UUID) {
        guard let operation = operationCoordinator.operations.first(where: { $0.id == id }) else {
            return
        }
        presentation = .transferCancellation(RemoteFileTransferCancellationRequest(
            id: id,
            kind: operation.kind == .upload ? .upload : .transfer
        ))
    }

    @MainActor
    func cancelTransfer(id: UUID) {
        operationCoordinator.cancel(id)
        dismissPresentation()
    }

    var trimmedNewFolderName: String {
        guard case .createFolder(let draft) = presentation else { return "" }
        return draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRenameSubmitting: Bool {
        guard case .rename(let draft) = presentation else { return false }
        return draft.isSubmitting
    }

    var isMoveSubmitting: Bool {
        guard case .move(let draft) = presentation else { return false }
        return draft.isSubmitting
    }

    var isPermissionSubmitting: Bool {
        guard case .permissions(let draft) = presentation else { return false }
        return draft.isSubmitting
    }

    var permissionOriginalAccessBits: UInt32 {
        guard case .permissions(let draft) = presentation else { return 0 }
        return draft.originalAccessBits
    }

    var permissionPreservedBits: UInt32 {
        guard case .permissions(let draft) = presentation else { return 0 }
        return draft.preservedBits
    }

    var permissionErrorMessage: String? {
        guard case .permissions(let draft) = presentation else { return nil }
        return draft.errorMessage
    }

    var createFolderNameBinding: Binding<String> {
        Binding(
            get: {
                guard case .createFolder(let draft) = presentation else { return "" }
                return draft.name
            },
            set: { name in
                guard case .createFolder(var draft) = presentation else { return }
                draft.name = name
                presentation = .createFolder(draft)
            }
        )
    }

    var renameNameBinding: Binding<String> {
        Binding(
            get: {
                guard case .rename(let draft) = presentation else { return "" }
                return draft.name
            },
            set: { name in
                guard case .rename(var draft) = presentation else { return }
                draft.name = name
                presentation = .rename(draft)
            }
        )
    }

    var moveDestinationBinding: Binding<String> {
        Binding(
            get: {
                guard case .move(let draft) = presentation else { return "" }
                return draft.destinationDirectory
            },
            set: { destination in
                guard case .move(var draft) = presentation else { return }
                draft.destinationDirectory = destination
                presentation = .move(draft)
            }
        )
    }

    var permissionDraftBinding: Binding<RemoteFilePermissionDraft> {
        Binding(
            get: {
                guard case .permissions(let draft) = presentation else {
                    return RemoteFilePermissionDraft(accessBits: 0)
                }
                return draft.permissions
            },
            set: { permissions in
                guard case .permissions(var draft) = presentation else { return }
                draft.permissions = permissions
                presentation = .permissions(draft)
            }
        )
    }

    func dismissPresentation() {
        presentation = nil
    }

    func handlePendingToolbarCommand() {
        guard let command = browser.pendingToolbarCommand,
              command.serverId == server.id,
              command.tabId == fileTab.id else {
            return
        }

        switch command.action {
        case .upload(let destinationPath):
            beginUpload(to: destinationPath)
        case .createFolder(let destinationPath):
            beginCreateFolder(in: destinationPath)
        }

        browser.consumeToolbarCommand(command)
    }

    @ViewBuilder
    func browserActionMenu(currentPath: String) -> some View {
        Button {
            beginUpload(to: currentPath)
        } label: {
            Label(String(localized: "Upload…"), systemImage: "square.and.arrow.up")
        }

        Button {
            beginCreateFolder(in: currentPath)
        } label: {
            Label(String(localized: "New Folder…"), systemImage: "folder.badge.plus")
        }

        Divider()

        Button {
            copyPathToClipboard(currentPath)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }
    }

    @ViewBuilder
    func entryActionMenu(_ entry: RemoteFileEntry) -> some View {
        switch entry.type {
        case .directory:
            Button {
                Task { await browser.openDirectory(entry, in: fileTab, server: server) }
            } label: {
                Label(String(localized: "Open"), systemImage: "folder")
            }

            Button {
                beginUpload(to: entry.path)
            } label: {
                Label(String(localized: "Upload…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginCreateFolder(in: entry.path)
            } label: {
                Label(String(localized: "New Folder…"), systemImage: "folder.badge.plus")
            }

            permissionMenuAction(for: entry)

        case .file, .other, .symlink:
            Button {
                previewEntry(entry)
            } label: {
                Label(String(localized: "Open"), systemImage: "doc.text")
            }

            Button {
                beginDownload(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }

            Button {
                beginShare(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginUpload(to: RemoteFilePath.parent(of: entry.path))
            } label: {
                Label(String(localized: "Upload Here…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginCreateFolder(in: RemoteFilePath.parent(of: entry.path))
            } label: {
                Label(String(localized: "New Folder Here…"), systemImage: "folder.badge.plus")
            }

            permissionMenuAction(for: entry)
        }

        Divider()

        renameAndMoveMenuActions(for: entry)
        deleteMenuAction(for: entry)

        Divider()

        clipboardMenuActions(for: entry)
    }

    @ViewBuilder
    func inspectorActionMenu(_ entry: RemoteFileEntry) -> some View {
        if entry.type != .directory {
            Button {
                beginDownload(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }

            Button {
                beginShare(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }

            Divider()
        }

        permissionMenuAction(for: entry)
        renameAndMoveMenuActions(for: entry)

        Divider()

        clipboardMenuActions(for: entry)

        Divider()

        deleteMenuAction(for: entry)
    }

    @ViewBuilder
    func permissionMenuAction(for entry: RemoteFileEntry) -> some View {
        if canEditPermissions(for: entry) {
            Button {
                beginEditPermissions(entry)
            } label: {
                Label(String(localized: "Permissions…"), systemImage: "lock.shield")
            }
        }
    }

    @ViewBuilder
    func renameAndMoveMenuActions(for entry: RemoteFileEntry) -> some View {
        Button {
            beginRename(entry)
        } label: {
            Label(String(localized: "Rename…"), systemImage: "pencil")
        }

        Button {
            beginMove(entry)
        } label: {
            Label(String(localized: "Move…"), systemImage: "arrow.right.circle")
        }
    }

    @ViewBuilder
    func clipboardMenuActions(for entry: RemoteFileEntry) -> some View {
        Button {
            Clipboard.copy(entry.name)
        } label: {
            Label(String(localized: "Copy Name"), systemImage: "textformat")
        }

        Button {
            copyPathToClipboard(entry.path)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }
    }

    func deleteMenuAction(for entry: RemoteFileEntry) -> some View {
        Button(role: .destructive) {
            requestDelete([entry])
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    func beginUpload(to remotePath: String) {
        platformBeginUpload(to: remotePath)
    }

    func beginDownload(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }
        platformBeginDownload(entry)
    }

    func beginShare(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }

        cleanupShareItem()

        operationCoordinator.prepareFile(
            entry,
            purpose: .share,
            browser: browser,
            tab: fileTab,
            server: server
        ) { file in
            presentation = .share(RemoteFileShareItem(
                id: file.id,
                sourceURL: file.url,
                title: file.filename
            ))
        }
    }

    func beginCreateFolder(in remotePath: String) {
        platformBeginCreateFolder(in: remotePath)
    }

    func beginRename(_ entry: RemoteFileEntry) {
        platformBeginRename(entry)
    }

    func beginMove(_ entry: RemoteFileEntry) {
        presentation = .move(.init(
            entry: entry,
            destinationDirectory: RemoteFilePath.parent(of: entry.path)
        ))
    }

    func beginEditPermissions(_ entry: RemoteFileEntry) {
        guard canEditPermissions(for: entry), let permissions = entry.permissions else { return }
        presentation = .permissions(.init(
            entry: entry,
            permissions: RemoteFilePermissionDraft(accessBits: permissions),
            originalAccessBits: permissions & 0o777,
            preservedBits: entry.specialPermissionBits,
            fileTypeBits: permissions & UInt32(LIBSSH2_SFTP_S_IFMT)
        ))
    }

    func canEditPermissions(for entry: RemoteFileEntry) -> Bool {
        guard entry.permissions != nil else { return false }
        switch entry.type {
        case .symlink:
            return false
        case .file, .directory, .other:
            return true
        }
    }

    func previewEntry(_ entry: RemoteFileEntry) {
        Task {
            await browser.activate(entry, in: fileTab, server: server)
            await platformDidActivatePreviewEntry(entry)
        }
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, toPresentedDestination destinationPath: String) {
        guard case .upload(let currentDestination) = presentation,
              currentDestination == destinationPath else { return }
        dismissPresentation()
        handleUploadSelection(result, to: destinationPath)
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, to destinationPath: String) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            beginUploadFlow(
                urls: urls,
                to: destinationPath,
                initialMessage: String(localized: "Preparing files for upload.")
            )
        case .failure(let error):
            presentOperationError(error)
        }
    }

    func handleDownloadExportCompletion(_ result: Result<URL, Error>) {
        guard case .downloadExport(let export) = presentation else { return }
        let transferID = export.transferID
        let noticeID = transferID.uuidString
        operationCoordinator.dismiss(transferID)

        switch result {
        case .success:
            cleanupDownloadExport()
            noticeHost.show(
                NoticeItem(
                    id: noticeID,
                    lane: .bottomOperation,
                    level: .success,
                    leading: .icon("checkmark.circle.fill"),
                    title: String(localized: "Downloading"),
                    message: String(localized: "Export complete."),
                    lifetime: .autoDismiss(.seconds(2))
                )
            )
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError {
                handleDownloadExportCancellation()
            } else {
                cleanupDownloadExport()
                noticeHost.show(
                    NoticeItem(
                        id: noticeID,
                        lane: .bottomOperation,
                        level: .error,
                        leading: .icon("xmark.octagon.fill"),
                        title: String(localized: "Downloading"),
                        message: remoteOperationErrorMessage(for: error),
                        dismissAction: { noticeHost.dismiss(id: noticeID) }
                    )
                )
            }
        }

    }

    func handleDownloadExportCancellation() {
        guard case .downloadExport(let export) = presentation else { return }
        cleanupDownloadExport()
        operationCoordinator.dismiss(export.transferID)
    }

    func beginUploadFlow(urls: [URL], to destinationPath: String, initialMessage: String) {
        operationCoordinator.upload(
            urls: urls,
            to: destinationPath,
            initialMessage: initialMessage,
            browser: browser,
            tab: fileTab,
            server: server
        )
    }

    func handleCurrentDirectoryDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        RemoteFileItemProviderAdapter.acceptsRemoteItems(providers)
            ? handleRemoteDrop(providers, to: destinationPath)
            : handleLocalDrop(providers, to: destinationPath)
    }

    func handleLocalDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        guard RemoteFileItemProviderAdapter.acceptsLocalItems(providers) else { return false }
        RemoteFileItemProviderAdapter.loadLocalItems(from: providers) { result in
            switch result {
            case .success(let urls):
                if !urls.isEmpty {
                    beginUploadFlow(
                        urls: urls,
                        to: destinationPath,
                        initialMessage: String(localized: "Preparing dropped files.")
                    )
                }
            case .failure(let error):
                presentOperationError(error)
            }
        }
        return true
    }

    func handleRemoteDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        guard RemoteFileItemProviderAdapter.acceptsRemoteItems(providers) else { return false }

        operationCoordinator.transferDroppedItems(
            to: destinationPath,
            browser: browser,
            tab: fileTab,
            server: server
        ) {
            try await RemoteFileItemProviderAdapter.loadRemotePayloads(from: providers)
        }

        return true
    }

    func handleFolderDrop(_ providers: [NSItemProvider], to entry: RemoteFileEntry) -> Bool {
        guard entry.type == .directory else { return false }
        return handleCurrentDirectoryDrop(providers, to: entry.path)
    }

    func dragItemProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        RemoteFileItemProviderAdapter.makeProvider(
            payload: RemoteFileDragPayload(serverId: server.id, entries: [entry]),
            entry: entry
        ) { entry in
            try await browser.prepareDragExport(for: entry, server: server)
        }
    }

    func createFolder() {
        guard case .createFolder(var draft) = presentation else { return }
        guard !draft.isSubmitting else { return }
        guard !trimmedNewFolderName.isEmpty else {
            resetNewFolderPrompt()
            return
        }
        draft.isSubmitting = true
        presentation = .createFolder(draft)
        let destinationPath = draft.destinationPath
        let folderNameInput = draft.name

        operationCoordinator.createFolder(
            named: folderNameInput,
            in: destinationPath,
            browser: browser,
            tab: fileTab,
            server: server,
            onSuccess: { _ in
                resetNewFolderPrompt()
            },
            onFailure: { error in
                guard case .createFolder(var current) = presentation,
                      current.destinationPath == destinationPath else { return }
                current.isSubmitting = false
                presentation = .createFolder(current)
                presentOperationError(error)
            }
        )
    }

    func renameEntry() {
        guard case .rename(var draft) = presentation, !draft.isSubmitting else { return }
        draft.isSubmitting = true
        presentation = .rename(draft)
        let entry = draft.entry
        let nameInput = draft.name

        operationCoordinator.rename(
            entry,
            to: nameInput,
            browser: browser,
            tab: fileTab,
            server: server,
            onSuccess: { _ in
                resetRenamePrompt()
            },
            onFailure: { error in
                guard case .rename(var current) = presentation,
                      current.entry.id == entry.id else { return }
                current.isSubmitting = false
                presentation = .rename(current)
                presentOperationError(error)
            }
        )
    }

    func moveEntry() {
        guard case .move(var draft) = presentation, !draft.isSubmitting else { return }
        draft.isSubmitting = true
        presentation = .move(draft)
        let entry = draft.entry
        let destinationInput = draft.destinationDirectory

        operationCoordinator.move(
            entry,
            to: destinationInput,
            browser: browser,
            tab: fileTab,
            server: server,
            onSuccess: {
                resetMovePrompt()
            },
            onFailure: { error in
                guard case .move(var current) = presentation,
                      current.entry.id == entry.id else { return }
                current.isSubmitting = false
                presentation = .move(current)
                presentOperationError(error)
            }
        )
    }

    func deleteEntry() {
        guard case .delete(let entry) = presentation else { return }
        dismissPresentation()

        deleteEntries([entry])
    }

    func deleteEntries(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }

        operationCoordinator.delete(
            entries,
            browser: browser,
            tab: fileTab,
            server: server,
            onFailure: { presentOperationError($0) }
        )
    }

    func requestDelete(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }
        platformRequestDelete(entries)
    }

    func resetNewFolderPrompt() {
        if case .createFolder = presentation { dismissPresentation() }
    }

    func resetRenamePrompt() {
        if case .rename = presentation { dismissPresentation() }
    }

    func resetMovePrompt() {
        if case .move = presentation { dismissPresentation() }
    }

    func applyPermissions() {
        guard case .permissions(var draft) = presentation, !draft.isSubmitting else { return }
        draft.errorMessage = nil
        draft.isSubmitting = true
        presentation = .permissions(draft)
        let entry = draft.entry
        operationCoordinator.changePermissions(
            for: entry,
            draft: draft.permissions,
            preservedBits: draft.preservedBits,
            fileTypeBits: draft.fileTypeBits,
            browser: browser,
            tab: fileTab,
            server: server,
            onSuccess: {
                resetPermissionEditor()
            },
            onFailure: { error in
                guard case .permissions(var current) = presentation,
                      current.entry.id == entry.id else { return }
                current.isSubmitting = false
                current.errorMessage = remoteOperationErrorMessage(for: error)
                presentation = .permissions(current)
            }
        )
    }

    func resetPermissionEditor() {
        if case .permissions = presentation { dismissPresentation() }
    }

    func cleanupDownloadExport() {
        guard case .downloadExport(let export) = presentation else { return }
        operationCoordinator.releasePreparedFile(export.transferID)
        dismissPresentation()
    }

    func cleanupShareItem() {
        guard case .share(let item) = presentation else { return }
        operationCoordinator.releasePreparedFile(item.id)
        dismissPresentation()
    }

    func finishSharing(_ item: RemoteFileShareItem) {
        guard case .share(let current) = presentation, current.id == item.id else { return }
        cleanupShareItem()
    }

    func currentFolderTitle(for path: String) -> String {
        RemoteFilePath.breadcrumbs(for: path).last?.title ?? "/"
    }

    func itemCountLabel(for count: Int) -> String {
        count == 1
            ? String(format: String(localized: "%lld item"), Int64(count))
            : String(format: String(localized: "%lld items"), Int64(count))
    }

    func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func deleteAlertTitle(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Delete Folder?")
        case .file:
            return String(localized: "Delete File?")
        case .symlink, .other:
            return String(localized: "Delete Item?")
        }
    }

    func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return RemoteFileByteCountFormatter.string(from: size)
    }

    func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            switch ext {
            case "yaml", "yml":
                return String(localized: "YAML Document")
            case "json":
                return String(localized: "JSON Document")
            case "md":
                return String(localized: "Markdown Document")
            case "txt", "log":
                return String(localized: "Text Document")
            case "swift":
                return String(localized: "Swift Source")
            case "sh", "bash", "zsh":
                return String(localized: "Shell Script")
            case "png", "jpg", "jpeg", "gif", "webp", "heic":
                return String(localized: "Image")
            case "zip", "tar", "gz", "tgz", "xz", "bz2":
                return String(localized: "Archive")
            default:
                return String(localized: "Document")
            }
        }
    }

}
