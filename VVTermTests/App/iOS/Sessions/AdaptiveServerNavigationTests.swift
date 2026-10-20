#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import VVTerm

@MainActor
final class AdaptiveServerNavigationTests: XCTestCase {
    func testCollapsedBackPreservesTheOutgoingDetailContent() throws {
        guard #available(iOS 27.1, *) else { throw XCTSkip("New phone layout policy") }
        func root(selected: Bool) -> some View {
            AdaptiveServerNavigation(hasSelection: selected, prefersSingleColumn: true) { _ in
                EmptyView()
            } detail: { _ in
                NavigationDetailLabel(text: selected ? "Terminal" : "Empty")
            }
        }
        let host = UIHostingController(rootView: root(selected: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var pending: [UIViewController] = [host]
        var detail: UIViewController?
        while let controller = pending.popLast() {
            if controller is UIHostingController<AnyView>,
               controller.view.viewWithTag(NavigationDetailLabel.tag) != nil {
                detail = controller
                break
            }
            pending.append(contentsOf: controller.children)
        }
        let outgoing = try XCTUnwrap(detail)
        host.rootView = root(selected: false)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual((outgoing.view.viewWithTag(NavigationDetailLabel.tag) as? UILabel)?.text, "Terminal",
                       "Back must keep the outgoing terminal instead of showing the empty destination during the animation.")
    }

    func testSelectionWaitsForTheDetailContentUpdateBeforeNavigation() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let split = RecordingSplitViewController(collapsed: true)
        coordinator.split = split
        coordinator.showDetail()
        XCTAssertTrue(split.shownColumns.isEmpty,
                      "The selection callback runs before SwiftUI updates the detail content.")
        coordinator.updateSelection(true)
        XCTAssertEqual(split.shownColumns, [.secondary])
    }

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

    func testNewOSUsesNativeColumnSizing() throws {
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
        XCTAssertEqual(actual.preferredPrimaryColumnWidth, native.preferredPrimaryColumnWidth)
        XCTAssertEqual(actual.preferredPrimaryColumnWidthFraction, native.preferredPrimaryColumnWidthFraction)
    }

    func testBackReturnsToServersWhenColumnsAreCollapsed() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let split = RecordingSplitViewController(collapsed: true)
        coordinator.split = split
        coordinator.updateSelection(true)
        XCTAssertEqual(split.shownColumns, [.secondary])
        coordinator.updateSelection(false)
        XCTAssertEqual(split.shownColumns, [.secondary, .primary])
        coordinator.updateSelection(false)
        XCTAssertEqual(split.shownColumns, [.secondary, .primary], "Repeated updates must not repeat navigation.")
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
        coordinator.updateSelection(true)
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
        let navigation = ServerNavigationController(rootViewController: coordinator.sidebar, column: .primary)
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

    func testDetailContentUpdateCannotRestoreTheOuterNavigationBar() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let navigation = ServerNavigationController(rootViewController: coordinator.sidebar, column: .primary)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        navigation.pushViewController(coordinator.detail, animated: false)
        navigation.view.layoutIfNeeded()
        XCTAssertTrue(navigation.isNavigationBarHidden)

        // The detail acquires its SwiftUI toolbar after the first native push.
        // A later bar update must not reserve space for a second toolbar.
        navigation.setNavigationBarHidden(false, animated: false)
        navigation.view.setNeedsLayout()
        navigation.view.layoutIfNeeded()
        XCTAssertTrue(navigation.isNavigationBarHidden)

        navigation.popViewController(animated: false)
        navigation.view.layoutIfNeeded()
        XCTAssertFalse(navigation.isNavigationBarHidden)
    }

    func testReturningSidebarRepairsALateHiddenNavigationBar() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let navigation = ServerNavigationController(rootViewController: coordinator.sidebar, column: .primary)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        navigation.pushViewController(coordinator.detail, animated: false)
        navigation.popViewController(animated: false)
        navigation.view.layoutIfNeeded()

        // A departing SwiftUI detail can update the bar after the native pop.
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.view.setNeedsLayout()
        navigation.view.layoutIfNeeded()
        XCTAssertFalse(navigation.isNavigationBarHidden,
                       "The visible sidebar must restore its own toolbar.")
    }
}

private struct NavigationDetailLabel: UIViewRepresentable {
    static let tag = 9153
    let text: String
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.tag = Self.tag
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) { label.text = text }
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
