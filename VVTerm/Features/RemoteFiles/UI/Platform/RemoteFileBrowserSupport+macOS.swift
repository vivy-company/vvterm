import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import ObjectiveC.runtime

struct RemoteFileSharePicker: NSViewRepresentable {
    let item: RemoteFileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.presentIfNeeded(item: item, from: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private let onComplete: () -> Void
        private var activeItemID: UUID?
        private var activePicker: NSSharingServicePicker?
        private var activeService: NSSharingService?
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func presentIfNeeded(item: RemoteFileShareItem, from view: NSView) {
            guard activeItemID != item.id else { return }

            activeItemID = item.id
            didFinish = false

            let picker = NSSharingServicePicker(items: [item.sourceURL])
            picker.delegate = self
            activePicker = picker

            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let service else {
                finish()
                return
            }

            activeService = service
            service.delegate = self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish()
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            finish()
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            activePicker = nil
            activeService = nil
            activeItemID = nil
            onComplete()
        }
    }
}

@MainActor
final class MacOSMenuActionTarget: NSObject {
    private let actionHandler: () -> Void

    init(actionHandler: @escaping () -> Void) {
        self.actionHandler = actionHandler
    }

    @objc
    func performAction(_ sender: Any?) {
        actionHandler()
    }
}

struct MacOSWindowTopInsetBridge: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowUpdate = { [topInset = _topInset] window in
            let safeArea = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let measuredTopInset = max(
                window.frame.height - window.contentLayoutRect.height,
                safeArea.top
            )

            if abs(topInset.wrappedValue - measuredTopInset) > 0.5 {
                topInset.wrappedValue = measuredTopInset
            }
        }
        nsView.triggerUpdate()
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.removeObservers()
    }

    final class WindowObserverView: NSView {
        var onWindowUpdate: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            triggerUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            triggerUpdate()
        }

        override func layout() {
            super.layout()
            triggerUpdate()
        }

        func triggerUpdate() {
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindowUpdate?(window)
            }
        }

        func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        private func installObservers() {
            removeObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            observers = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.triggerUpdate()
                    }
                }
            }
        }

        isolated deinit {
            removeObservers()
        }
    }
}

struct MacOSRemoteFileTableView: NSViewRepresentable {
    let entries: [RemoteFileEntry]
    let currentPath: String
    let selectedPaths: Set<String>
    let sort: RemoteFileSort
    let sortDirection: RemoteFileSortDirection
    let inlineCreateFolderParentPath: String?
    let inlineRenamePath: String?
    let inlineProposedName: String
    let isInlineSubmitting: Bool
    let onSelectionChange: @MainActor (Set<String>, NSEvent.ModifierFlags) -> Void
    let onActivate: @MainActor (RemoteFileEntry) -> Void
    let onSortChange: @MainActor (RemoteFileSort, RemoteFileSortDirection) -> Void
    let onUploadDroppedURLs: @MainActor ([URL], String) -> Void
    let onDropRemotePayload: @MainActor (RemoteFileDragPayload, String) -> Void
    let onBeginRemoteDrag: @MainActor (RemoteFileDragPayload) -> Void
    let onEndRemoteDrag: @MainActor () -> Void
    let activeRemoteDragPayload: @MainActor () -> RemoteFileDragPayload?
    let menuForEntry: @MainActor (RemoteFileEntry) -> NSMenu
    let menuForBackground: @MainActor () -> NSMenu
    let exportEntry: @MainActor (RemoteFileEntry, URL) async throws -> Void
    let fileTypeIdentifier: (RemoteFileEntry) -> String
    let kindLabel: (RemoteFileEntry) -> String
    let onSubmitInlineEdit: @MainActor (String) -> Void
    let onCancelInlineEdit: @MainActor () -> Void
    let serverId: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(scrollView: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum RowKind {
            case inlineCreatePlaceholder
            case entry(index: Int)
        }

        struct TableRenderState: Equatable {
            let entries: [RemoteFileEntry]
            let currentPath: String
            let sort: RemoteFileSort
            let sortDirection: RemoteFileSortDirection
            let inlineCreateFolderParentPath: String?
            let inlineRenamePath: String?
            let inlineProposedName: String
            let isInlineSubmitting: Bool

            init(parent: MacOSRemoteFileTableView) {
                entries = parent.entries
                currentPath = parent.currentPath
                sort = parent.sort
                sortDirection = parent.sortDirection
                inlineCreateFolderParentPath = parent.inlineCreateFolderParentPath
                inlineRenamePath = parent.inlineRenamePath
                inlineProposedName = parent.inlineProposedName
                isInlineSubmitting = parent.isInlineSubmitting
            }
        }

        var parent: MacOSRemoteFileTableView
        private let tableView = RemoteFileTableView()
        private let scrollView = NSScrollView()
        private var isUpdatingSelection = false
        private var promiseDelegates: [UUID: FilePromiseDelegate] = [:]
        private var currentDropRow: Int = -1
        private var currentDropOperation: NSTableView.DropOperation = .on
        private var activeInlineEditorIdentity: String?
        private var lastRenderedState: TableRenderState?

        init(_ parent: MacOSRemoteFileTableView) {
            self.parent = parent
        }

        func makeScrollView() -> NSScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.documentView = tableView

            tableView.headerView = NSTableHeaderView()
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnReordering = false
            tableView.allowsColumnResizing = true
            tableView.allowsTypeSelect = true
            tableView.focusRingType = .none
            tableView.style = .inset
            tableView.rowHeight = 32
            tableView.intercellSpacing = NSSize(width: 8, height: 0)
            tableView.backgroundColor = .clear
            tableView.selectionHighlightStyle = .regular
            tableView.draggingDestinationFeedbackStyle = .regular
            tableView.delegate = self
            tableView.dataSource = self
            tableView.menuProvider = { [weak self] row in
                guard let self else { return nil }
                if let row, let rowKind = self.rowKind(for: row) {
                    switch rowKind {
                    case .inlineCreatePlaceholder:
                        return self.parent.menuForBackground()
                    case .entry(let index):
                        let entry = self.parent.entries[index]
                        self.selectRowIfNeeded(row)
                        return self.parent.menuForEntry(entry)
                    }
                }
                return self.parent.menuForBackground()
            }
            tableView.onSelectAll = { [weak self] in
                guard let self else { return }
                let allPaths = Set(self.parent.entries.map(\.id))
                self.parent.onSelectionChange(allPaths, [])
            }
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleAction(_:))
            let draggedTypes = Array(
                Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
            )
            tableView.registerForDraggedTypes(draggedTypes)
            tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
            tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

            configureColumns()
            applySortDescriptors()

            return scrollView
        }

        func update(scrollView: NSScrollView) {
            let renderState = TableRenderState(parent: parent)
            let shouldReloadData = lastRenderedState != renderState
            lastRenderedState = renderState

            if shouldReloadData {
                tableView.reloadData()
                applySortDescriptors()
            }

            syncSelection()
            if shouldReloadData || inlineEditorIdentity != nil {
                tableView.layoutSubtreeIfNeeded()
            }
            syncInlineEditorFocus()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.entries.count + (inlineCreateRowIndex == nil ? 0 : 1)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rowKind(for: row) {
            case .inlineCreatePlaceholder:
                return 30
            case .entry(let index):
                let entry = parent.entries[index]
                return entry.type == .symlink && entry.symlinkTarget != nil ? 38 : 30
            case .none:
                return 30
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let rowKind = rowKind(for: row) else { return nil }

            switch ColumnID(rawValue: tableColumn.identifier.rawValue) {
            case .name:
                let view = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NameCellView
                    ?? NameCellView()
                view.identifier = tableColumn.identifier
                switch rowKind {
                case .inlineCreatePlaceholder:
                    view.configureInlineEditing(
                        iconName: "folder.fill",
                        iconTintColor: .systemBlue,
                        title: parent.inlineProposedName.isEmpty ? String(localized: "New Folder") : parent.inlineProposedName,
                        subtitle: "",
                        proposedName: parent.inlineProposedName,
                        isSubmitting: parent.isInlineSubmitting,
                        onSubmit: parent.onSubmitInlineEdit,
                        onCancel: parent.onCancelInlineEdit
                    )
                case .entry(let index):
                    let entry = parent.entries[index]
                    if parent.inlineRenamePath == entry.path {
                        view.configureInlineEditing(
                            iconName: entry.iconName,
                            iconTintColor: entry.type == .directory ? .systemBlue : .secondaryLabelColor,
                            title: entry.name,
                            subtitle: entry.type == .symlink ? (entry.symlinkTarget ?? "") : "",
                            proposedName: parent.inlineProposedName,
                            isSubmitting: parent.isInlineSubmitting,
                            onSubmit: parent.onSubmitInlineEdit,
                            onCancel: parent.onCancelInlineEdit
                        )
                    } else {
                        view.configure(entry: entry)
                    }
                }
                return view
            case .modifiedAt:
                guard case .entry(let index) = rowKind else {
                    return makeTextCell(
                        tableView: tableView,
                        identifier: tableColumn.identifier,
                        text: "",
                        alignment: .left
                    )
                }
                let entry = parent.entries[index]
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                    alignment: .left
                )
            case .size:
                guard case .entry(let index) = rowKind else {
                    return makeTextCell(
                        tableView: tableView,
                        identifier: tableColumn.identifier,
                        text: "",
                        alignment: .right
                    )
                }
                let entry = parent.entries[index]
                let sizeText = entry.type == .directory || entry.size == nil
                    ? "—"
                    : RemoteFileByteCountFormatter.string(from: entry.size ?? 0)
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: sizeText,
                    alignment: .right
                )
            case .kind:
                guard case .entry(let index) = rowKind else {
                    return makeTextCell(
                        tableView: tableView,
                        identifier: tableColumn.identifier,
                        text: "",
                        alignment: .left
                    )
                }
                let entry = parent.entries[index]
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: parent.kindLabel(entry),
                    alignment: .left
                )
            case .none:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection else { return }
            let selectedPaths: [String] = tableView.selectedRowIndexes.compactMap { index in
                guard case .entry(let entryIndex) = rowKind(for: index) else { return nil }
                return parent.entries[entryIndex].id
            }
            let selected = Set(selectedPaths)
            parent.onSelectionChange(selected, NSApp.currentEvent?.modifierFlags ?? [])
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = ColumnID(rawValue: descriptor.key ?? "") else { return }
            let direction: RemoteFileSortDirection = descriptor.ascending ? .ascending : .descending
            switch column {
            case .name:
                parent.onSortChange(.name, direction)
            case .modifiedAt:
                parent.onSortChange(.modifiedAt, direction)
            case .size:
                parent.onSortChange(.size, direction)
            case .kind:
                return
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard case .entry(let index) = rowKind(for: row) else { return nil }
            let entry = parent.entries[index]
            let delegate = FilePromiseDelegate(
                entry: entry,
                fileTypeIdentifier: parent.fileTypeIdentifier(entry),
                export: parent.exportEntry
            )
            promiseDelegates[delegate.id] = delegate
            return delegate.makeProvider()
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            let draggedEntries = rowIndexes.compactMap { index -> RemoteFileEntry? in
                guard case .entry(let entryIndex) = rowKind(for: index) else { return nil }
                return parent.entries[entryIndex]
            }
            parent.onBeginRemoteDrag(RemoteFileDragPayload(
                serverId: parent.serverId,
                entries: draggedEntries
            ))
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            parent.onEndRemoteDrag()
            promiseDelegates.removeAll()
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            retargetDrop(on: tableView, proposedRow: row, dropOperation: dropOperation)
            let destinationPath = destinationPath(
                for: currentDropRow,
                dropOperation: currentDropOperation
            )
            guard destinationPath != nil else { return [] }

            if let source = parent.activeRemoteDragPayload(), !source.entries.isEmpty {
                return source.serverId == parent.serverId ? .move : .copy
            }

            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            return fileURLs.isEmpty ? [] : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let destinationPath = destinationPath(
                for: currentDropRow,
                dropOperation: currentDropOperation
            ) else { return false }

            if let payload = parent.activeRemoteDragPayload(), !payload.entries.isEmpty {
                parent.onDropRemotePayload(payload, destinationPath)
                return true
            }

            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            guard !fileURLs.isEmpty else { return false }
            parent.onUploadDroppedURLs(fileURLs, destinationPath)
            return true
        }

        @objc
        private func handleDoubleAction(_ sender: Any?) {
            let row = tableView.clickedRow
            guard case .entry(let index) = rowKind(for: row) else { return }
            parent.onActivate(parent.entries[index])
        }

        private func destinationPath(for row: Int, dropOperation: NSTableView.DropOperation) -> String? {
            if row == -1 {
                return parent.currentPath
            }

            if dropOperation == .on, case .entry(let index) = rowKind(for: row) {
                let entry = parent.entries[index]
                return entry.type == .directory ? entry.path : nil
            }

            return parent.currentPath
        }

        private func retargetDrop(
            on tableView: NSTableView,
            proposedRow row: Int,
            dropOperation: NSTableView.DropOperation
        ) {
            guard let rowKind = rowKind(for: row) else {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
                return
            }

            guard case .entry(let index) = rowKind else {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
                return
            }

            let entry = parent.entries[index]
            if entry.type == .directory {
                currentDropRow = row
                currentDropOperation = .on
                tableView.setDropRow(row, dropOperation: .on)
            } else if dropOperation == .above {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
            } else {
                currentDropRow = row
                currentDropOperation = dropOperation
            }
        }

        private func syncSelection() {
            let rowIndexes: IndexSet
            if let inlineCreateRowIndex {
                rowIndexes = IndexSet(integer: inlineCreateRowIndex)
            } else {
                rowIndexes = IndexSet(
                    parent.entries.enumerated().compactMap { index, entry in
                        guard parent.selectedPaths.contains(entry.id) else { return nil }
                        return displayRow(forEntryIndex: index)
                    }
                )
            }
            guard tableView.selectedRowIndexes != rowIndexes else { return }
            isUpdatingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isUpdatingSelection = false
        }

        private func syncInlineEditorFocus() {
            let identity = inlineEditorIdentity
            guard let identity else {
                activeInlineEditorIdentity = nil
                return
            }

            guard let editRow = inlineEditingDisplayRow,
                  let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ColumnID.name.rawValue)) else {
                activeInlineEditorIdentity = identity
                return
            }

            tableView.scrollRowToVisible(editRow)
            tableView.layoutSubtreeIfNeeded()

            let columnIndex = tableView.column(withIdentifier: nameColumn.identifier)
            guard columnIndex >= 0,
                  let cell = tableView.view(atColumn: columnIndex, row: editRow, makeIfNecessary: true) as? NameCellView else {
                activeInlineEditorIdentity = identity
                return
            }

            let shouldRestoreFocus = activeInlineEditorIdentity != identity || !cell.isEditingActive
            activeInlineEditorIdentity = identity

            if shouldRestoreFocus {
                cell.requestEditingFocus()
            }
        }

        private func configureColumns() {
            tableView.tableColumns.forEach(tableView.removeTableColumn)

            tableView.addTableColumn(makeColumn(id: .name, title: String(localized: "Name"), width: 280, minWidth: 140))
            tableView.addTableColumn(makeColumn(id: .modifiedAt, title: String(localized: "Date Modified"), width: 200, minWidth: 120))
            tableView.addTableColumn(makeColumn(id: .size, title: String(localized: "Size"), width: 90, minWidth: 60))
            tableView.addTableColumn(makeColumn(id: .kind, title: String(localized: "Kind"), width: 150, minWidth: 90))
        }

        private func makeColumn(id: ColumnID, title: String, width: CGFloat, minWidth: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.resizingMask = .autoresizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: sortAscending(for: id))
            return column
        }

        private func sortAscending(for column: ColumnID) -> Bool {
            switch column {
            case .name:
                return parent.sort == .name ? parent.sortDirection == .ascending : true
            case .modifiedAt:
                return parent.sort == .modifiedAt ? parent.sortDirection == .ascending : false
            case .size:
                return parent.sort == .size ? parent.sortDirection == .ascending : false
            case .kind:
                return true
            }
        }

        private func applySortDescriptors() {
            guard let targetColumn = ColumnID(sort: parent.sort),
                  let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(targetColumn.rawValue)) else {
                return
            }

            let targetDescriptor = NSSortDescriptor(
                key: targetColumn.rawValue,
                ascending: parent.sortDirection == .ascending
            )
            if tableView.sortDescriptors != [targetDescriptor] {
                tableView.sortDescriptors = [targetDescriptor]
            }
            column.sortDescriptorPrototype = targetDescriptor
        }

        private func makeTextCell(
            tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            text: String,
            alignment: NSTextAlignment
        ) -> NSView {
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCellView ?? TextCellView()
            cell.identifier = identifier
            cell.configure(text: text, alignment: alignment)
            return cell
        }

        private func selectRowIfNeeded(_ row: Int) {
            guard row >= 0 else { return }
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        private var inlineEditorIdentity: String? {
            if let parentPath = parent.inlineCreateFolderParentPath, parent.currentPath == parentPath {
                return "create:\(parentPath)"
            }
            if let inlineRenamePath = parent.inlineRenamePath {
                return "rename:\(inlineRenamePath)"
            }
            return nil
        }

        private var inlineCreateRowIndex: Int? {
            guard let parentPath = parent.inlineCreateFolderParentPath,
                  parent.currentPath == parentPath else { return nil }

            let placeholder = RemoteFileEntry(
                name: parent.inlineProposedName,
                path: RemoteFilePath.appending(parent.inlineProposedName, to: parent.currentPath),
                type: .directory,
                size: nil,
                modifiedAt: nil,
                permissions: nil,
                symlinkTarget: nil
            )

            for (index, entry) in parent.entries.enumerated() where sortsBefore(placeholder, entry) {
                return index
            }
            return parent.entries.count
        }

        private var inlineEditingDisplayRow: Int? {
            if let inlineCreateRowIndex {
                return inlineCreateRowIndex
            }

            guard let inlineRenamePath = parent.inlineRenamePath,
                  let entryIndex = parent.entries.firstIndex(where: { $0.path == inlineRenamePath }) else {
                return nil
            }

            return displayRow(forEntryIndex: entryIndex)
        }

        private func rowKind(for row: Int) -> RowKind? {
            guard row >= 0, row < numberOfRows(in: tableView) else { return nil }

            if let inlineCreateRowIndex {
                if row == inlineCreateRowIndex {
                    return .inlineCreatePlaceholder
                }
                return .entry(index: row > inlineCreateRowIndex ? row - 1 : row)
            }

            guard parent.entries.indices.contains(row) else { return nil }
            return .entry(index: row)
        }

        private func displayRow(forEntryIndex entryIndex: Int) -> Int {
            if let inlineCreateRowIndex, entryIndex >= inlineCreateRowIndex {
                return entryIndex + 1
            }
            return entryIndex
        }

        private func sortsBefore(_ lhs: RemoteFileEntry, _ rhs: RemoteFileEntry) -> Bool {
            let lhsDirectoryRank = lhs.type == .directory ? 0 : 1
            let rhsDirectoryRank = rhs.type == .directory ? 0 : 1
            if lhsDirectoryRank != rhsDirectoryRank {
                return lhsDirectoryRank < rhsDirectoryRank
            }

            switch parent.sort {
            case .name:
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison != .orderedSame {
                    return parent.sortDirection == .ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            case .modifiedAt:
                let lhsDate = lhs.modifiedAt ?? .distantPast
                let rhsDate = rhs.modifiedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return parent.sortDirection == .ascending ? lhsDate < rhsDate : lhsDate > rhsDate
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                let lhsSize = lhs.size ?? 0
                let rhsSize = rhs.size ?? 0
                if lhsSize != rhsSize {
                    return parent.sortDirection == .ascending ? lhsSize < rhsSize : lhsSize > rhsSize
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private enum ColumnID: String {
        case name
        case modifiedAt
        case size
        case kind

        init?(sort: RemoteFileSort) {
            switch sort {
            case .name: self = .name
            case .modifiedAt: self = .modifiedAt
            case .size: self = .size
            }
        }
    }

    final class RemoteFileTableView: NSTableView {
        var menuProvider: ((Int?) -> NSMenu?)?
        var onSelectAll: (() -> Void)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let location = convert(event.locationInWindow, from: nil)
            let row = self.row(at: location)
            return menuProvider?(row >= 0 ? row : nil)
        }

        override func selectAll(_ sender: Any?) {
            super.selectAll(sender)
            onSelectAll?()
        }
    }

    final class NameCellView: NSTableCellView, NSTextFieldDelegate {
        private let iconView = NSImageView()
        private let titleField = NSTextField(labelWithString: "")
        private let subtitleField = NSTextField(labelWithString: "")
        private let editorField = InlineEditingTextField(string: "")
        private let progressIndicator = NSProgressIndicator()
        private var isConfiguringEditor = false
        private var suppressNextEndEditing = false
        private var onSubmit: ((String) -> Void)?
        private var onCancel: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

            titleField.translatesAutoresizingMaskIntoConstraints = false
            titleField.lineBreakMode = .byTruncatingTail
            titleField.font = .systemFont(ofSize: NSFont.systemFontSize)

            subtitleField.translatesAutoresizingMaskIntoConstraints = false
            subtitleField.lineBreakMode = .byTruncatingTail
            subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleField.textColor = .secondaryLabelColor

            editorField.translatesAutoresizingMaskIntoConstraints = false
            editorField.font = .systemFont(ofSize: NSFont.systemFontSize)
            editorField.isBordered = false
            editorField.isBezeled = false
            editorField.drawsBackground = true
            editorField.backgroundColor = .textBackgroundColor
            editorField.focusRingType = .none
            editorField.lineBreakMode = .byTruncatingTail
            editorField.delegate = self
            editorField.wantsLayer = true
            editorField.onCancelOperation = { [weak self] in
                self?.onCancel?()
            }
            editorField.isHidden = true

            progressIndicator.translatesAutoresizingMaskIntoConstraints = false
            progressIndicator.controlSize = .small
            progressIndicator.style = .spinning
            progressIndicator.isDisplayedWhenStopped = false
            progressIndicator.isHidden = true

            let stack = NSStackView(views: [titleField, subtitleField])
            stack.orientation = .vertical
            stack.spacing = 1
            stack.alignment = .leading
            stack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(iconView)
            addSubview(stack)
            addSubview(editorField)
            addSubview(progressIndicator)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 18),
                iconView.heightAnchor.constraint(equalToConstant: 18),

                stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -6),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),

                editorField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                editorField.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -6),
                editorField.centerYAnchor.constraint(equalTo: centerYAnchor),
                editorField.heightAnchor.constraint(equalToConstant: 24),

                progressIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(entry: RemoteFileEntry) {
            onSubmit = nil
            onCancel = nil
            suppressNextEndEditing = false
            titleField.stringValue = entry.name
            subtitleField.stringValue = entry.type == .symlink ? (entry.symlinkTarget ?? "") : ""
            subtitleField.isHidden = subtitleField.stringValue.isEmpty
            iconView.image = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: entry.name)
            iconView.contentTintColor = entry.type == .directory ? .systemBlue : .secondaryLabelColor
            titleField.isHidden = false
            editorField.isHidden = true
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
        }

        func configureInlineEditing(
            iconName: String,
            iconTintColor: NSColor,
            title: String,
            subtitle: String,
            proposedName: String,
            isSubmitting: Bool,
            onSubmit: @escaping (String) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            suppressNextEndEditing = false

            titleField.stringValue = title
            subtitleField.stringValue = subtitle
            subtitleField.isHidden = true
            iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: title)
            iconView.contentTintColor = iconTintColor

            isConfiguringEditor = true
            editorField.stringValue = proposedName
            editorField.isEditable = !isSubmitting
            editorField.isSelectable = !isSubmitting
            editorField.textColor = isSubmitting ? .secondaryLabelColor : .labelColor
            editorField.placeholderString = proposedName.isEmpty ? title : nil
            editorField.applyInlineEditingAppearance(isSubmitting: isSubmitting)
            isConfiguringEditor = false

            titleField.isHidden = true
            editorField.isHidden = false
            progressIndicator.isHidden = !isSubmitting
            if isSubmitting {
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.stopAnimation(nil)
            }
        }

        func requestEditingFocus() {
            guard !editorField.isHidden, !editorField.isHiddenOrHasHiddenAncestor, editorField.window != nil else { return }
            editorField.window?.makeFirstResponder(editorField)
            editorField.applyInlineEditingAppearance(isFocused: true, isSubmitting: !editorField.isEditable)
            DispatchQueue.main.async { [weak self] in
                guard let self, let editor = self.editorField.currentEditor() else { return }
                editor.selectedRange = NSRange(location: 0, length: self.editorField.stringValue.count)
            }
        }

        var isEditingActive: Bool {
            guard let window = editorField.window else { return false }
            return window.firstResponder === editorField || window.firstResponder === editorField.currentEditor()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !editorField.isHidden, !isConfiguringEditor else { return }
            if suppressNextEndEditing {
                suppressNextEndEditing = false
                return
            }
            editorField.applyInlineEditingAppearance(isFocused: false, isSubmitting: !editorField.isEditable)
            let movement = notification.userInfo?["NSTextMovement"] as? Int ?? NSIllegalTextMovement
            if movement == NSCancelTextMovement {
                onCancel?()
                return
            }
            onSubmit?(editorField.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                suppressNextEndEditing = true
                onSubmit?(editorField.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                suppressNextEndEditing = true
                onCancel?()
                return true
            default:
                return false
            }
        }
    }

    final class TextCellView: NSTableCellView {
        private let label = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .secondaryLabelColor
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(text: String, alignment: NSTextAlignment) {
            label.stringValue = text
            label.alignment = alignment
        }
    }

    final class InlineEditingTextField: NSTextField {
        override class var cellClass: AnyClass? {
            get { InlineEditingTextFieldCell.self }
            set {}
        }

        var onCancelOperation: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureAppearance()
        }

        convenience init(string: String) {
            self.init(frame: .zero)
            stringValue = string
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func cancelOperation(_ sender: Any?) {
            onCancelOperation?()
        }

        func applyInlineEditingAppearance(isFocused: Bool = false, isSubmitting: Bool) {
            guard let layer else { return }

            let borderColor: NSColor
            if isSubmitting {
                borderColor = .separatorColor
            } else if isFocused {
                borderColor = .controlAccentColor
            } else {
                borderColor = .quaternaryLabelColor
            }

            layer.borderColor = borderColor.cgColor
            alphaValue = isSubmitting ? 0.8 : 1.0
        }

        override func textDidBeginEditing(_ notification: Notification) {
            super.textDidBeginEditing(notification)
            applyInlineEditingAppearance(isFocused: true, isSubmitting: !isEditable)
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            applyInlineEditingAppearance(isFocused: false, isSubmitting: !isEditable)
        }

        private func configureAppearance() {
            focusRingType = .none
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            textColor = .labelColor
            applyInlineEditingAppearance(isSubmitting: false)
        }
    }

    final class InlineEditingTextFieldCell: NSTextFieldCell {
        private let horizontalInset: CGFloat = 8
        private let verticalInset: CGFloat = 3

        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            insetBounds(rect)
        }

        override func edit(
            withFrame rect: NSRect,
            in controlView: NSView,
            editor textObj: NSText,
            delegate: Any?,
            event: NSEvent?
        ) {
            super.edit(
                withFrame: insetBounds(rect),
                in: controlView,
                editor: textObj,
                delegate: delegate,
                event: event
            )
        }

        override func select(
            withFrame rect: NSRect,
            in controlView: NSView,
            editor textObj: NSText,
            delegate: Any?,
            start selStart: Int,
            length selLength: Int
        ) {
            super.select(
                withFrame: insetBounds(rect),
                in: controlView,
                editor: textObj,
                delegate: delegate,
                start: selStart,
                length: selLength
            )
        }

        private func insetBounds(_ rect: NSRect) -> NSRect {
            rect.insetBy(dx: horizontalInset, dy: verticalInset)
        }
    }

    final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        let id = UUID()
        private let entry: RemoteFileEntry
        private let fileTypeIdentifier: String
        private let export: @MainActor (RemoteFileEntry, URL) async throws -> Void

        init(
            entry: RemoteFileEntry,
            fileTypeIdentifier: String,
            export: @escaping @MainActor (RemoteFileEntry, URL) async throws -> Void
        ) {
            self.entry = entry
            self.fileTypeIdentifier = fileTypeIdentifier
            self.export = export
        }

        func makeProvider() -> NSFilePromiseProvider {
            NSFilePromiseProvider(fileType: fileTypeIdentifier, delegate: self)
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            .main
        }

        func promisedFileName(for fileType: String) -> String {
            let fallbackName = entry.type == .directory ? "Folder" : "download"
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? fallbackName : trimmedName
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            promisedFileName(for: fileType)
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            Task { @MainActor in
                do {
                    try await export(entry, url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

}

private var macOSMenuActionTargetAssociationKey: UInt8 = 0

@MainActor
func makeMacOSMenuItem(
    title: String,
    systemImage: String? = nil,
    keyEquivalent: String = "",
    modifierMask: NSEvent.ModifierFlags = [],
    action: @escaping () -> Void
) -> NSMenuItem {
    let item = NSMenuItem(
        title: title,
        action: #selector(MacOSMenuActionTarget.performAction(_:)),
        keyEquivalent: keyEquivalent
    )
    item.keyEquivalentModifierMask = modifierMask
    if let systemImage {
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    }

    let target = MacOSMenuActionTarget(actionHandler: action)
    item.target = target
    objc_setAssociatedObject(
        item,
        &macOSMenuActionTargetAssociationKey,
        target,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return item
}

func makeMacOSSeparatorMenuItem() -> NSMenuItem {
    .separator()
}
#endif
