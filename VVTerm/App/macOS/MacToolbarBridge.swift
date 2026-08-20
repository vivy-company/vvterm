//
//  MacToolbarBridge.swift
//  VVTerm
//
//  Typed SwiftUI to AppKit toolbar presentation state.
//

#if os(macOS)
import Combine
import SwiftUI

enum MacToolbarCommandID: Equatable {
    case selectView(String)
    case filesParent
    case filesRefresh
    case filesUpload
    case filesNewFolder
    case filesToggleHidden
    case filesCopyPath
    case openSettings
    case editServer
    case disconnect
    case enterZen
}

struct ToolbarMenuEntry: Equatable {
    let command: MacToolbarCommandID?
    var title: String
    var systemImage: String?
    var isEnabled: Bool = true
    var isDestructive: Bool = false

    static let separator = ToolbarMenuEntry(
        command: nil,
        title: "-",
        systemImage: nil,
        isEnabled: false
    )

    var isSeparator: Bool { command == nil }
}

struct ToolbarViewPickerData: Equatable {
    struct Segment: Equatable {
        let id: String
        let systemImage: String
        let help: String
    }

    var segments: [Segment]
    var selectedId: String
}

struct MacToolbarSnapshot: Equatable {
    var ownerId: String?
    var showsViewPicker = false
    var showsTabStrip = false
    var showsFilesMenu = false
    var isZenMode = false
    var zenTitle = ""
    var zenIcon = ""
    var zenSubtitle = ""
    var viewPicker: ToolbarViewPickerData?
    var filesMenu: [ToolbarMenuEntry] = []
    var serverMenu: [ToolbarMenuEntry] = []

    var isActive: Bool { ownerId != nil }
    static let inactive = MacToolbarSnapshot()
}

@MainActor
final class MacToolbarCommandDispatcher {
    private var ownerId: String?
    private var handler: (MacToolbarCommandID) -> Void = { _ in }

    func install(ownerId: String, handler: @escaping (MacToolbarCommandID) -> Void) {
        self.ownerId = ownerId
        self.handler = handler
    }

    func clear(ownerId: String) {
        guard self.ownerId == ownerId else { return }
        self.ownerId = nil
        handler = { _ in }
    }

    func dispatch(_ command: MacToolbarCommandID) {
        handler(command)
    }
}

@MainActor
final class MacToolbarBridge: ObservableObject {
    static let shared = MacToolbarBridge()

    @Published private(set) var snapshot: MacToolbarSnapshot = .inactive
    let dispatcher = MacToolbarCommandDispatcher()

    // Type erasure is limited to the dynamic SwiftUI content hosted by AppKit.
    private var tabStripProvider: () -> AnyView = { AnyView(EmptyView()) }
    private var zenPanelProvider: () -> AnyView = { AnyView(EmptyView()) }

    private init() {}

    func activate<TabStrip: View, ZenPanel: View>(
        snapshot: MacToolbarSnapshot,
        dispatch: @escaping (MacToolbarCommandID) -> Void,
        @ViewBuilder tabStrip: @escaping () -> TabStrip,
        @ViewBuilder zenPanel: @escaping () -> ZenPanel
    ) {
        guard let ownerId = snapshot.ownerId else { return }
        dispatcher.install(ownerId: ownerId, handler: dispatch)
        tabStripProvider = { AnyView(tabStrip()) }
        zenPanelProvider = { AnyView(zenPanel()) }
        self.snapshot = snapshot
    }

    func deactivate(ownerId: String) {
        guard snapshot.ownerId == ownerId else { return }
        dispatcher.clear(ownerId: ownerId)
        tabStripProvider = { AnyView(EmptyView()) }
        zenPanelProvider = { AnyView(EmptyView()) }
        snapshot = .inactive
    }

    func makeTabStripView() -> AnyView {
        tabStripProvider()
    }

    func makeZenPanelView() -> AnyView {
        zenPanelProvider()
    }
}
#endif
