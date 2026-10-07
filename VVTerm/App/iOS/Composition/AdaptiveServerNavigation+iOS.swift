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
        // Native sizing on Duo can align both columns with the active fold.
        if #unavailable(iOS 27.1) {
            split.minimumPrimaryColumnWidth = 260
            split.maximumPrimaryColumnWidth = 380
            split.preferredPrimaryColumnWidthFraction = 0.28
        }
        for (host, column) in [(coordinator.sidebar, UISplitViewController.Column.primary), (coordinator.detail, .secondary)] {
            let navigation = UINavigationController(rootViewController: host)
            // The primary uses the native bar to reserve space for iPad window controls.
            navigation.setNavigationBarHidden(column == .secondary, animated: false)
            if column == .primary { navigation.delegate = coordinator }
            split.setViewController(navigation, for: column)
        }
        updateUIViewController(split, context: context)
        return split
    }

    func updateUIViewController(_ split: UISplitViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.updateSelection(hasSelection)
        coordinator.updateLayout(prefersSingleColumn: prefersSingleColumn)
        coordinator.sidebar.rootView = AnyView(
            sidebar { [weak coordinator] in coordinator?.showDetail() }
                .environment(\.self, context.environment)
        )
        coordinator.detail.rootView = AnyView(
            NavigationStack { detail { [weak coordinator] in coordinator?.toggleSidebar() } }
                // This root also participates in UIKit's collapsed navigation stack.
                .navigationBarBackButtonHidden(true)
                .environment(\.self, context.environment)
        )
    }

    final class Coordinator: NSObject, UISplitViewControllerDelegate, UINavigationControllerDelegate {
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
            let clearedSelection = self.hasSelection && !hasSelection
            self.hasSelection = hasSelection
            if clearedSelection, let split, split.isCollapsed {
                split.show(.primary)
            }
        }

        func navigationController(_ navigationController: UINavigationController,
                                  willShow viewController: UIViewController, animated: Bool) {
            // On collapse, UIKit moves the detail into the primary navigation stack.
            // Its SwiftUI NavigationStack already owns the detail toolbar.
            navigationController.setNavigationBarHidden(viewController !== sidebar, animated: animated)
        }

        func showDetail() {
            guard let split else { return }
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
