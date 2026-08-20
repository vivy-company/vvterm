//
//  MacShellSplitHost.swift
//  VVTerm
//
//  AppKit-owned macOS shell: hosts the SwiftUI sidebar and detail panes inside
//  an NSSplitViewController so the window's toolbar can be owned by AppKit
//  (NSToolbar) instead of SwiftUI's NavigationSplitView. NavigationSplitView
//  owns the window toolbar and will not allow a custom NSToolbar to coexist;
//  hosting the same SwiftUI panes under an NSSplitViewController removes that
//  ownership so a native, fill-capable toolbar can be installed.
//

#if os(macOS)
import Combine
import SwiftUI
import AppKit

nonisolated enum MacShellContentReplacementPolicy {
    static func shouldReplace(current: AnyHashable?, next: AnyHashable) -> Bool {
        current != next
    }
}

/// Wraps an `NSSplitViewController` (sidebar + detail) and bridges it into the
/// SwiftUI `WindowGroup`. The hosted SwiftUI panes are passed in already
/// wrapped with the required environment, since environment values do not flow
/// across an `NSHostingController` boundary automatically.
struct MacShellSplitHost<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let isSidebarCollapsed: Bool
    let sidebarContentIdentity: AnyHashable
    let detailContentIdentity: AnyHashable
    var onToggleSidebar: () -> Void = {}
    /// Hides the window toolbar (zen mode) and restores it on exit.
    var isToolbarHidden: Bool = false
    var sidebarMinWidth: CGFloat = 200
    var sidebarIdealWidth: CGFloat = 250
    var sidebarMaxWidth: CGFloat = 300
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    func makeCoordinator() -> MacShellSplitHostCoordinator {
        MacShellSplitHostCoordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let coordinator = context.coordinator

        let sidebarHC = NSHostingController(rootView: AnyView(sidebar()))
        let detailHC = NSHostingController(rootView: AnyView(detail()))
        coordinator.sidebarHostingController = sidebarHC
        coordinator.detailHostingController = detailHC
        coordinator.sidebarContentIdentity = sidebarContentIdentity
        coordinator.detailContentIdentity = detailContentIdentity

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHC)
        sidebarItem.minimumThickness = sidebarMinWidth
        sidebarItem.maximumThickness = sidebarMaxWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        coordinator.sidebarItem = sidebarItem

        let detailItem = NSSplitViewItem(viewController: detailHC)
        detailItem.minimumThickness = 400
        detailItem.canCollapse = false

        let splitVC = ShellSplitViewController()
        splitVC.splitView.dividerStyle = .thin
        splitVC.splitView.autosaveName = "vvterm.mac.sidebar"
        splitVC.initialSidebarWidth = sidebarIdealWidth
        splitVC.onToggleSidebar = onToggleSidebar
        splitVC.isToolbarHidden = isToolbarHidden
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(detailItem)
        coordinator.splitViewController = splitVC

        // Apply initial collapse state.
        sidebarItem.isCollapsed = isSidebarCollapsed

        return splitVC
    }

    func updateNSViewController(_ nsViewController: NSSplitViewController, context: Context) {
        let coordinator = context.coordinator
        if MacShellContentReplacementPolicy.shouldReplace(
            current: coordinator.sidebarContentIdentity,
            next: sidebarContentIdentity
        ) {
            coordinator.sidebarContentIdentity = sidebarContentIdentity
            coordinator.sidebarHostingController?.rootView = AnyView(sidebar())
        }
        if MacShellContentReplacementPolicy.shouldReplace(
            current: coordinator.detailContentIdentity,
            next: detailContentIdentity
        ) {
            coordinator.detailContentIdentity = detailContentIdentity
            coordinator.detailHostingController?.rootView = AnyView(detail())
        }
        (nsViewController as? ShellSplitViewController)?.onToggleSidebar = onToggleSidebar
        (nsViewController as? ShellSplitViewController)?.updateToolbarHidden(isToolbarHidden)

        if let item = coordinator.sidebarItem, item.isCollapsed != isSidebarCollapsed {
            item.animator().isCollapsed = isSidebarCollapsed
        }
    }
}

final class MacShellSplitHostCoordinator {
    var splitViewController: NSSplitViewController?
    var sidebarHostingController: NSHostingController<AnyView>?
    var detailHostingController: NSHostingController<AnyView>?
    var sidebarItem: NSSplitViewItem?
    var sidebarContentIdentity: AnyHashable?
    var detailContentIdentity: AnyHashable?
}

/// NSSplitViewController that applies an initial sidebar width once, since
/// NSSplitViewItem has no "ideal" thickness.
final class ShellSplitViewController: NSSplitViewController {
    var initialSidebarWidth: CGFloat = 250
    var onToggleSidebar: (() -> Void)?
    var isToolbarHidden = false
    private var didApplyInitialWidth = false
    private var bridgeObserver: AnyCancellable?

    /// Hide/show the window toolbar for zen mode.
    func updateToolbarHidden(_ hidden: Bool) {
        isToolbarHidden = hidden
        view.window?.toolbar?.isVisible = !hidden
    }

    /// The system `.toggleSidebar` toolbar item targets this. Route it through
    /// the SwiftUI columnVisibility (single source of truth) instead of letting
    /// NSSplitViewController collapse the item directly, which would fight the
    /// SwiftUI-driven collapse state.
    override func toggleSidebar(_ sender: Any?) {
        if let onToggleSidebar {
            onToggleSidebar()
        } else {
            super.toggleSidebar(sender)
        }
    }

    private func updateZenWindowTitle() {
        guard let window = view.window else { return }
        let snapshot = MacToolbarBridge.shared.snapshot
        let shouldShowTitle = snapshot.isActive
            && snapshot.isZenMode
            && !snapshot.zenTitle.isEmpty

        if shouldShowTitle {
            window.title = snapshot.zenTitle
            window.subtitle = snapshot.zenSubtitle
            window.titleVisibility = .visible
        } else {
            window.subtitle = ""
            window.titleVisibility = .hidden
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbarIfNeeded()
        if bridgeObserver == nil {
            bridgeObserver = MacToolbarBridge.shared.$snapshot
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateZenWindowTitle() }
        }
        updateZenWindowTitle()
        guard !didApplyInitialWidth else { return }
        didApplyInitialWidth = true
        // Only set the initial position when autosave did not already restore one.
        guard splitView.subviews.count >= 2 else { return }
        let current = splitView.subviews[0].frame.width
        if current < 1 || current.isNaN {
            splitView.setPosition(initialSidebarWidth, ofDividerAt: 0)
        }
    }

    private func installToolbarIfNeeded() {
        guard let window = view.window else { return }
        let toolbar = MacConnectionToolbarController.shared.toolbar
        if window.toolbar !== toolbar {
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }
        window.toolbar?.isVisible = !isToolbarHidden
    }
}
#endif
