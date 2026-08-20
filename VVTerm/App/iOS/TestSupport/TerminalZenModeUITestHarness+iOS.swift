#if os(iOS) && DEBUG
import SwiftUI

struct TerminalZenModeUITestHarness: View {
    private static let paneId = UUID(uuidString: "5E798DA7-3488-4D78-BEE0-7E01E241A31E")!

    @EnvironmentObject private var ghosttyApp: GhosttyRuntime
    private let tabManager: TerminalTabManager
    @State private var isZenModeEnabled = false
    @State private var showingZenPanel = false
    @State private var selectedView = ConnectionViewTabID.terminal
    @State private var selectedTerminalTabId: UUID?
    @State private var selectedFileTabId: UUID?
    @State private var terminalView: GhosttyTerminalView?
    @State private var terminalReady = false

    init(tabManager: TerminalTabManager) {
        self.tabManager = tabManager
    }

    var body: some View {
        NavigationStack {
            TerminalKeyboardHarnessRepresentable(
                tabManager: tabManager,
                terminalView: $terminalView,
                terminalReady: $terminalReady,
                focusRequestID: 0,
                paneId: Self.paneId,
                surfaceIdentifier: "vvterm.zenTest.terminalSurface",
                surfaceLabel: "Zen Mode Terminal Test Surface",
                onInput: { _ in },
                onZoomAction: { _ in },
                onPaneKeyboardShortcut: { _ in },
                onPaneFocus: { }
            )
                .background(.black)
                .overlay(alignment: .topTrailing) {
                    if isZenModeEnabled {
                        ZenModeFloatingOverlay(isPanelPresented: $showingZenPanel) { width in
                            IOSZenModePanel(
                                width: width,
                                serverName: "Test Server",
                                selectedView: selectedView,
                                selectedViewBinding: $selectedView,
                                viewTabs: [.terminal, .files],
                                terminalTabs: [],
                                selectedTerminalTabId: $selectedTerminalTabId,
                                terminalTabTitle: { _ in "Test Terminal" },
                                paneState: { _ in nil },
                                onCloseTerminalTab: { _ in },
                                fileTabs: [],
                                selectedFileTabId: $selectedFileTabId,
                                fileTabTitle: { _ in "Test Files" },
                                onSelectFileTab: { _ in },
                                onCloseFileTab: { _ in },
                                onNewTerminalTab: {},
                                onNewFileTab: {},
                                onOpenSettings: {},
                                onEditServer: {},
                                onDisconnect: {},
                                onBack: {},
                                onExitZen: exitZenMode
                            )
                        }
                    }
                }
                .navigationTitle("Test Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Chrome") {}
                            .accessibilityIdentifier("vvterm.zenTest.chrome")
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    isZenModeEnabled = true
                                }
                            } label: {
                                Label("Enter Zen Mode", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .accessibilityIdentifier("vvterm.terminal.enterZenMode")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("vvterm.terminal.moreMenu")
                    }
                }
                .toolbar(isZenModeEnabled ? .hidden : .visible, for: .navigationBar)
        }
        .task {
            ghosttyApp.startIfNeeded()
        }
    }

    private func exitZenMode() {
        showingZenPanel = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isZenModeEnabled = false
        }
    }
}
#endif
