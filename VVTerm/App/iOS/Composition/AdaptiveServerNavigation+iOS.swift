#if os(iOS)
import SwiftUI
import UIKit

/// Keeps both SwiftUI roots in native columns while UIKit adapts to window width.
struct AdaptiveServerNavigation<Sidebar: View, Detail: View>: UIViewControllerRepresentable {
    let hasSelection: Bool
    var prefersSingleColumn = false
    let sidebar: (@escaping () -> Void) -> Sidebar
    let detail: (@escaping () -> Void) -> Detail

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UISplitViewController {
        let split = UISplitViewController(style: .doubleColumn)
        let coordinator = context.coordinator
        coordinator.split = split
        split.delegate = coordinator
        split.preferredDisplayMode = .oneBesideSecondary
        if #available(iOS 27.1, *), UIDevice.current.userInterfaceIdiom == .phone {
            split.preferredSplitBehavior = .overlay
            split.preferredDisplayMode = hasSelection ? .secondaryOnly : .oneOverSecondary
        }
        // The detail toolbar provides the toggle in both expanded and collapsed layouts.
        split.displayModeButtonVisibility = .never
        coordinator.sidebar.view.backgroundColor = .clear
        split.primaryBackgroundStyle = .sidebar
        // Native column sizing lets UIKit align the columns with the fold.
        if #unavailable(iOS 27.1) {
            split.minimumPrimaryColumnWidth = 260
            split.maximumPrimaryColumnWidth = 380
            split.preferredPrimaryColumnWidthFraction = 0.28
        }
        for (host, column) in [(coordinator.sidebar, UISplitViewController.Column.primary), (coordinator.detail, .secondary)] {
            let navigation = ServerNavigationController(rootViewController: host, column: column)
            // The primary uses the native bar to reserve space for iPad window controls.
            navigation.setNavigationBarHidden(column == .secondary, animated: false)
            split.setViewController(navigation, for: column)
        }
        updateUIViewController(split, context: context)
        return split
    }

    func updateUIViewController(_ split: UISplitViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.updateLayout(prefersSingleColumn: prefersSingleColumn)
        coordinator.sidebar.rootView = AnyView(
            sidebar { [weak coordinator] in coordinator?.showDetail() }
                .environment(\.self, context.environment)
        )
        // A collapsed Back transition still displays its outgoing detail.
        // Keep that content until the native pop finishes.
        if hasSelection || (!prefersSingleColumn && !split.isCollapsed) {
            coordinator.detail.rootView = AnyView(
                NavigationStack { detail { [weak coordinator] in coordinator?.toggleSidebar() } }
                    // This root also participates in UIKit's collapsed navigation stack.
                    .navigationBarBackButtonHidden(true)
                    .environment(\.self, context.environment)
            )
        }
        coordinator.updateSelection(hasSelection)
    }

    final class Coordinator: NSObject, UISplitViewControllerDelegate {
        weak var split: UISplitViewController?
        let sidebar = UIHostingController(rootView: AnyView(EmptyView()))
        let detail = UIHostingController(rootView: AnyView(EmptyView().navigationBarBackButtonHidden(true)))
        var hasSelection = false

        func updateLayout(prefersSingleColumn: Bool) {
            guard #available(iOS 27.1, *), let split else { return }
            if prefersSingleColumn {
                split.traitOverrides.horizontalSizeClass = .compact
            } else {
                split.traitOverrides.remove(UITraitHorizontalSizeClass.self)
            }
        }

        func updateSelection(_ hasSelection: Bool) {
            let openedSelection = !self.hasSelection && hasSelection
            let clearedSelection = self.hasSelection && !hasSelection
            self.hasSelection = hasSelection
            if openedSelection {
                showDetail()
            } else if clearedSelection, let split, split.isCollapsed {
                split.show(.primary)
                if let transition = split.transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { [weak self] _ in
                        self?.clearInactiveDetail()
                    }
                } else {
                    clearInactiveDetail()
                }
            }
        }

        private func clearInactiveDetail() {
            guard !hasSelection, split?.isCollapsed == true,
                  detail.viewIfLoaded?.window == nil else { return }
            detail.rootView = AnyView(EmptyView().navigationBarBackButtonHidden(true))
        }

        func showDetail() {
            guard hasSelection, let split else { return }
            if split.isCollapsed {
                split.show(.secondary)
            } else if split.displayMode == .oneOverSecondary {
                split.hide(.primary)
            }
        }

        func toggleSidebar() {
            guard let split else { return }
            if split.isCollapsed || split.displayMode == .secondaryOnly {
                split.show(.primary)
            } else {
                split.hide(.primary)
            }
        }

        func splitViewController(_ svc: UISplitViewController,
                                 topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
            hasSelection ? .secondary : .primary
        }
    }
}
#endif
