//
//  MacConnectionToolbarController.swift
//  VVTerm
//
//  Custom AppKit NSToolbar for the macOS shell. The shell uses
//  NSSplitViewController (not NavigationSplitView), so the app owns the window
//  toolbar. Native AppKit controls are used for everything except the tab strip
//  (which stays SwiftUI, hosted in a flexible item that AppKit stretches to fill
//  and overflows natively). Using real toolbar controls gives the standard
//  bordered/glass button chrome and correct leading layout.
//

#if os(macOS)
import Combine
import SwiftUI
import AppKit

extension NSToolbarItem.Identifier {
    static let vvViewPicker = NSToolbarItem.Identifier("vvterm.viewPicker")
    static let vvTabStrip = NSToolbarItem.Identifier("vvterm.tabStrip")
    static let vvFilesMenu = NSToolbarItem.Identifier("vvterm.filesMenu")
    static let vvEnterZen = NSToolbarItem.Identifier("vvterm.enterZen")
    static let vvServerMenu = NSToolbarItem.Identifier("vvterm.serverMenu")
    static let vvZenControls = NSToolbarItem.Identifier("vvterm.zenControls")
}

/// Hosts the SwiftUI tab strip and re-renders as tabs/selection/view change.
private struct MacTabStripHost: View {
    @ObservedObject var bridge = MacToolbarBridge.shared

    var body: some View {
        bridge.makeTabStripView()
            .frame(
                maxWidth: .infinity,
                minHeight: ServerViewTopTabBarMetrics.toolbarTabStripHeight,
                maxHeight: ServerViewTopTabBarMetrics.toolbarTabStripHeight
            )
    }
}

/// Hosts the SwiftUI zen panel inside the zen controls popover.
private struct MacZenControlHost: View {
    @ObservedObject var bridge = MacToolbarBridge.shared

    var body: some View {
        bridge.makeZenPanelView()
    }
}

final class MacConnectionToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    static let shared = MacConnectionToolbarController()

    let toolbar: NSToolbar
    private let bridge = MacToolbarBridge.shared
    private weak var tabManager: TerminalTabManager?
    private var cancellable: AnyCancellable?
    private var currentPicker: ToolbarViewPickerData?
    private var zenPopover: NSPopover?
    private weak var segmentedControl: NSSegmentedControl?

    // The pull-down menus are rebuilt lazily (NSMenuDelegate) right before they
    // open, keyed by these identifiers, not on every snapshot update.
    private static let filesMenuIdentifier = NSUserInterfaceItemIdentifier("vvterm.filesMenu.menu")
    private static let serverMenuIdentifier = NSUserInterfaceItemIdentifier("vvterm.serverMenu.menu")

    override init() {
        toolbar = NSToolbar(identifier: "vvterm.connection.toolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        cancellable = bridge.$snapshot
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
    }

    func configure(tabManager: TerminalTabManager) {
        if let currentManager = self.tabManager {
            precondition(
                currentManager === tabManager,
                "Mac toolbar received a different terminal manager"
            )
        }
        self.tabManager = tabManager
        reconcile()
    }

    private var desiredIdentifiers: [NSToolbarItem.Identifier] {
        let snapshot = bridge.snapshot
        // Leading flexible space puts the sidebar toggle at the right edge of
        // the sidebar region (next to the divider), the standard macOS spot.
        var ids: [NSToolbarItem.Identifier] = [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator]
        guard tabManager != nil else { return ids }
        guard snapshot.isActive else { return ids }
        if snapshot.isZenMode {
            // Keep the sidebar toggle at the right edge of the sidebar section,
            // then let AppKit render the native window title/subtitle in the
            // content-side titlebar area.
            return [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .vvZenControls]
        }
        if snapshot.showsViewPicker { ids.append(.vvViewPicker) }
        if snapshot.showsTabStrip {
            ids.append(.vvTabStrip)
            // In terminal there is no Files button to separate the tabs from
            // the trailing zen/server group, so add a fixed gap. A real .space
            // item is required: it breaks the Liquid Glass grouping so the tab
            // strip and the zen/server group get separate capsules (a custom
            // spacer view stays in the same glass group and merges them). Files
            // view already gets that separation from the Files button itself.
            if !snapshot.showsFilesMenu { ids.append(.space) }
        } else {
            // No tabs in this view (e.g. Stats) — push trailing buttons right.
            ids.append(.flexibleSpace)
        }
        if snapshot.showsFilesMenu { ids.append(.vvFilesMenu) }
        ids.append(.vvEnterZen)
        ids.append(.vvServerMenu)
        return ids
    }

    private func reconcile() {
        guard tabManager != nil else { return }
        let desired = desiredIdentifiers
        let current = toolbar.items.map { $0.itemIdentifier }
        guard desired != current else {
            refreshContent()
            return
        }
        zenPopover?.performClose(nil)
        while !toolbar.items.isEmpty {
            toolbar.removeItem(at: toolbar.items.count - 1)
        }
        for (index, identifier) in desired.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        refreshContent()
    }

    /// Update native control state (segmented selection) to match the current
    /// bridge content. Menus are not rebuilt here — they refresh lazily on open
    /// via `menuNeedsUpdate(_:)`.
    private func refreshContent() {
        guard let segmented = segmentedControl, let picker = bridge.snapshot.viewPicker else { return }
        currentPicker = picker
        if segmented.segmentCount != picker.segments.count {
            configureSegmentedControl(segmented)
        } else if let index = picker.segments.firstIndex(where: { $0.id == picker.selectedId }),
                  segmented.selectedSegment != index {
            segmented.selectedSegment = index
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        desiredIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .vvViewPicker, .vvTabStrip,
         .vvFilesMenu, .vvEnterZen, .vvServerMenu, .vvZenControls,
         .flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .vvViewPicker:
            return makeViewPickerItem()
        case .vvTabStrip:
            return makeTabStripItem()
        case .vvFilesMenu:
            return makeFilesMenuItem()
        case .vvEnterZen:
            return makeEnterZenItem()
        case .vvServerMenu:
            return makeServerMenuItem()
        case .vvZenControls:
            return makeZenControlsItem()
        default:
            return nil
        }
    }

    private func makeZenControlsItem() -> NSToolbarItem {
        // Native bordered toolbar item → a real glass circle like the sidebar
        // toggle. Clicking presents the rich SwiftUI panel as an NSPopover
        // (with arrow) anchored to the item via show(relativeTo:) (macOS 14+).
        let item = NSToolbarItem(itemIdentifier: .vvZenControls)
        item.label = "Zen Controls"
        item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Zen Controls")
        item.isBordered = true
        item.target = self
        item.action = #selector(zenControlsTapped(_:))
        return item
    }

    @objc private func zenControlsTapped(_ sender: NSToolbarItem) {
        if let popover = zenPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MacZenControlHost())
        zenPopover = popover
        if #available(macOS 14.0, *) {
            popover.show(relativeTo: sender)
        } else if let anchor = NSApp.keyWindow?.contentView {
            popover.show(relativeTo: .zero, of: anchor, preferredEdge: .maxY)
        }
    }

    // MARK: Item builders

    private func makeViewPickerItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .vvViewPicker)
        item.label = "View"
        item.visibilityPriority = .high

        let segmented = NSSegmentedControl()
        segmented.trackingMode = .selectOne
        applyMacOS27TabRoleIfAvailable(to: segmented)
        segmented.target = self
        segmented.action = #selector(viewSegmentChanged(_:))
        configureSegmentedControl(segmented)
        segmentedControl = segmented
        item.view = segmented
        return item
    }

    private func applyMacOS27TabRoleIfAvailable(to segmented: NSSegmentedControl) {
        let setRoleSelector = NSSelectorFromString("setRole:")
        guard segmented.responds(to: setRoleSelector) else { return }

        // macOS 27+: NSSegmentedControl.Role.tabs gives the Activity Monitor
        // look. Use KVC so this still compiles with SDKs/toolchains whose Swift
        // AppKit import does not expose NSSegmentedControl.role yet.
        segmented.setValue(NSNumber(value: 1), forKey: "role")
    }

    private func configureSegmentedControl(_ segmented: NSSegmentedControl) {
        guard let picker = bridge.snapshot.viewPicker else {
            segmented.segmentCount = 0
            return
        }
        currentPicker = picker
        segmented.segmentCount = picker.segments.count
        for (index, segment) in picker.segments.enumerated() {
            segmented.setImage(
                NSImage(systemSymbolName: segment.systemImage, accessibilityDescription: segment.help),
                forSegment: index
            )
            segmented.setWidth(0, forSegment: index)
            segmented.setToolTip(segment.help, forSegment: index)
        }
        if let index = picker.segments.firstIndex(where: { $0.id == picker.selectedId }) {
            segmented.selectedSegment = index
        }
    }

    @objc private func viewSegmentChanged(_ sender: NSSegmentedControl) {
        guard let picker = currentPicker,
              sender.selectedSegment >= 0,
              sender.selectedSegment < picker.segments.count else { return }
        bridge.dispatcher.dispatch(
            .selectView(picker.segments[sender.selectedSegment].id)
        )
    }

    private func makeTabStripItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .vvTabStrip)
        item.label = "Tabs"
        // Keep the tab strip out of the overflow (») menu at all costs: outrank
        // every other item so they overflow first, and let it shrink (tabs
        // scroll internally) rather than collapse to the chevron.
        item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: 2000)
        let host = NSHostingView(
            rootView: MacTabStripHost()
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        // Report only a small minimum to the toolbar (not the greedy
        // maxWidth:.infinity intrinsic width). Otherwise NSToolbar treats the
        // strip as needing huge space and pushes it into the overflow menu. The
        // floor is below the resolver's per-tab minimum so the strip can shrink
        // (and scroll its tabs) before any other item overflows.
        host.sizingOptions = [.minSize]
        host.heightAnchor.constraint(
            equalToConstant: ServerViewTopTabBarMetrics.toolbarTabStripHeight
        ).isActive = true
        host.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        // Low horizontal hugging so the toolbar stretches it to fill (the
        // constraint-based replacement for the deprecated maxSize).
        host.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        item.view = host
        return item
    }

    private func makeFilesMenuItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .vvFilesMenu)
        item.label = "Files"
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Files")
        item.isBordered = true
        item.showsIndicator = true
        item.menu = makeLazyMenu(identifier: Self.filesMenuIdentifier)
        return item
    }

    private func makeServerMenuItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .vvServerMenu)
        item.label = "Server"
        item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Server")
        item.isBordered = true
        item.showsIndicator = false
        item.menu = makeLazyMenu(identifier: Self.serverMenuIdentifier)
        return item
    }

    private func makeEnterZenItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .vvEnterZen)
        item.label = "Zen"
        item.toolTip = "Enter Zen Mode"
        item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Zen")
        item.isBordered = true
        item.target = self
        item.action = #selector(enterZenTapped)
        return item
    }

    @objc private func enterZenTapped() {
        bridge.dispatcher.dispatch(.enterZen)
    }

    private func makeLazyMenu(identifier: NSUserInterfaceItemIdentifier) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.identifier = identifier
        menu.delegate = self
        return menu
    }

    /// Rebuild the about-to-open menu from the current bridge entries. Called by
    /// AppKit just before display, so the menus stay fresh without being rebuilt
    /// on every snapshot update.
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier {
        case Self.filesMenuIdentifier:
            populate(menu, with: bridge.snapshot.filesMenu)
        case Self.serverMenuIdentifier:
            populate(menu, with: bridge.snapshot.serverMenu)
        default:
            break
        }
    }

    private func populate(_ menu: NSMenu, with entries: [ToolbarMenuEntry]) {
        menu.removeAllItems()
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            // The closure lives in representedObject so we avoid subclassing
            // NSMenuItem (AppKit copies menu items via the designated
            // initializer, which a closure-carrying subclass can't honor).
            let menuItem = NSMenuItem(title: entry.title, action: #selector(menuItemFired(_:)), keyEquivalent: "")
            menuItem.target = self
            guard let command = entry.command else { continue }
            menuItem.representedObject = MenuActionBox(command)
            menuItem.isEnabled = entry.isEnabled
            if let systemImage = entry.systemImage {
                menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: entry.title)
            }
            menu.addItem(menuItem)
        }
    }

    @objc private func menuItemFired(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? MenuActionBox)?.command else { return }
        bridge.dispatcher.dispatch(command)
    }
}

/// Boxes a typed command for storage in NSMenuItem.representedObject.
private final class MenuActionBox {
    let command: MacToolbarCommandID
    init(_ command: MacToolbarCommandID) { self.command = command }
}
#endif
