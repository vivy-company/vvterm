#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import VVTerm

@MainActor
final class AdaptiveServerNavigationTests: XCTestCase {
    func testNarrowPhoneLayoutUsesOneColumnAndWideLayoutRestoresNativeTraits() throws {
        guard #available(iOS 27.1, *) else { throw XCTSkip("New phone layout policy") }
        XCTAssertTrue(ServerNavigationLayoutPolicy.prefersSingleColumn(availableWidth: 740, isPhone: true))
        XCTAssertFalse(ServerNavigationLayoutPolicy.prefersSingleColumn(availableWidth: 800, isPhone: true))
        XCTAssertFalse(ServerNavigationLayoutPolicy.prefersSingleColumn(availableWidth: 740, isPhone: false))
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let split = UISplitViewController(style: .doubleColumn)
        coordinator.split = split
        coordinator.updateLayout(prefersSingleColumn: true)
        XCTAssertEqual(split.traitCollection.horizontalSizeClass, .compact)
        XCTAssertTrue(split.traitOverrides.contains(UITraitHorizontalSizeClass.self))
        coordinator.updateLayout(prefersSingleColumn: false)
        XCTAssertFalse(split.traitOverrides.contains(UITraitHorizontalSizeClass.self),
                       "Wide layouts must return column adaptation to UIKit.")
    }

    func testNewOSKeepsNativeColumnSizingForFoldAdaptation() throws {
        guard #available(iOS 27.1, *) else {
            throw XCTSkip("Native fold adaptation requires iOS 27.1.")
        }
        let host = UIHostingController(rootView: AdaptiveServerNavigation(hasSelection: false) { _ in
            EmptyView()
        } detail: { _ in
            EmptyView()
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        var pending: [UIViewController] = [host]
        var split: UISplitViewController?
        while let controller = pending.popLast() {
            if let found = controller as? UISplitViewController {
                split = found
                break
            }
            pending.append(contentsOf: controller.children)
        }
        let actual = try XCTUnwrap(split)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertEqual(actual.preferredSplitBehavior, .overlay)
        }
        let native = UISplitViewController(style: .doubleColumn)
        XCTAssertEqual(actual.minimumPrimaryColumnWidth, native.minimumPrimaryColumnWidth)
        XCTAssertEqual(actual.maximumPrimaryColumnWidth, native.maximumPrimaryColumnWidth)
        XCTAssertEqual(actual.preferredPrimaryColumnWidthFraction, native.preferredPrimaryColumnWidthFraction)
    }

    func testBackReturnsToServersWhenColumnsAreCollapsed() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let split = RecordingSplitViewController(collapsed: true)
        coordinator.split = split
        coordinator.updateSelection(true)
        XCTAssertTrue(split.shownColumns.isEmpty)
        coordinator.updateSelection(false)
        XCTAssertEqual(split.shownColumns, [.primary])
        coordinator.updateSelection(false)
        XCTAssertEqual(split.shownColumns, [.primary], "Repeated updates must not repeat navigation.")
    }

    func testClearingSelectionKeepsExpandedColumnsInPlace() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let split = RecordingSplitViewController(collapsed: false)
        coordinator.split = split
        coordinator.updateSelection(true)
        coordinator.updateSelection(false)
        XCTAssertTrue(split.shownColumns.isEmpty)
    }

    func testSelectingDetailClosesOverlayButKeepsTiledSidebar() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let split = RecordingSplitViewController(collapsed: false)
        coordinator.split = split
        split.simulatedDisplayMode = .oneOverSecondary
        coordinator.showDetail()
        XCTAssertEqual(split.hiddenColumns, [.primary])
        split.simulatedDisplayMode = .oneBesideSecondary
        coordinator.showDetail()
        XCTAssertEqual(split.hiddenColumns, [.primary],
                       "Selecting a server must keep an expanded tiled sidebar visible.")
    }

    func testCollapseKeepsSelectedDetailAndOtherwiseShowsServers() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let split = UISplitViewController(style: .doubleColumn)
        XCTAssertEqual(coordinator.splitViewController(
            split, topColumnForCollapsingToProposedTopColumn: .secondary
        ), .primary)
        coordinator.updateSelection(true)
        XCTAssertEqual(coordinator.splitViewController(
            split, topColumnForCollapsingToProposedTopColumn: .primary
        ), .secondary)
        coordinator.updateSelection(false)
        XCTAssertEqual(coordinator.splitViewController(
            split, topColumnForCollapsingToProposedTopColumn: .secondary
        ), .primary)
    }

    func testCollapsedDetailHidesOuterBarAndReturningRestoresIt() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let navigation = UINavigationController(rootViewController: coordinator.sidebar)
        navigation.delegate = coordinator
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        navigation.view.layoutIfNeeded()
        XCTAssertFalse(navigation.isNavigationBarHidden)
        XCTAssertFalse(coordinator.sidebar.navigationItem.hidesBackButton)

        // The split controller pushes its secondary controller into this stack on collapse.
        navigation.pushViewController(coordinator.detail, animated: false)
        navigation.view.layoutIfNeeded()
        XCTAssertTrue(navigation.isNavigationBarHidden)
        XCTAssertTrue(coordinator.detail.navigationItem.hidesBackButton,
                      "The native detail must not add a Back button beside the SwiftUI Back button.")

        navigation.popViewController(animated: false)
        navigation.view.layoutIfNeeded()
        XCTAssertFalse(navigation.isNavigationBarHidden)
    }
}

private final class RecordingSplitViewController: UISplitViewController {
    private let simulatedCollapse: Bool
    private(set) var shownColumns: [UISplitViewController.Column] = []
    private(set) var hiddenColumns: [UISplitViewController.Column] = []
    var simulatedDisplayMode: UISplitViewController.DisplayMode = .oneBesideSecondary

    init(collapsed: Bool) {
        self.simulatedCollapse = collapsed
        super.init(style: .doubleColumn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isCollapsed: Bool { simulatedCollapse }
    override var displayMode: UISplitViewController.DisplayMode { simulatedDisplayMode }

    override func hide(_ column: UISplitViewController.Column) {
        hiddenColumns.append(column)
    }

    override func show(_ column: UISplitViewController.Column) {
        shownColumns.append(column)
    }
}
#endif
