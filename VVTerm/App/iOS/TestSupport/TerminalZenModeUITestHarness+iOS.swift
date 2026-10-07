#if os(iOS) && DEBUG
import SwiftUI

struct TerminalZenModeUITestHarness: View {
    private static let paneId = UUID(uuidString: "5E798DA7-3488-4D78-BEE0-7E01E241A31E")!
    private static let tabId = UUID(uuidString: "D31B3C04-44DA-4102-897D-BA5B3A851427")!
    private static let server = Server(
        workspaceId: UUID(),
        name: "Test Server",
        host: "test.example.com",
        username: "root"
    )
    private static let terminalTab = TerminalTab(
        id: tabId,
        serverId: server.id,
        title: "Test Terminal",
        rootPaneId: paneId
    )

    private static var initialFloatingControlPreferences: TerminalFloatingControlPreferences {
        var preferences = TerminalFloatingControlPreferences.defaultValue
        if Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-floating-control-hidden-left"
        ) {
            preferences.hiddenSide = .left
            preferences.horizontalFraction = 0
        }
        return preferences.normalized()
    }

    @EnvironmentObject private var ghosttyApp: GhosttyRuntime
    private let tabManager: TerminalTabManager
    private let voiceInputRuntimeStore: VoiceInputRuntimeStore
    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @ObservedObject private var floatingVoiceOperation: VoiceRecordingOperationCoordinator
    @State private var isZenModeEnabled = false
    @State private var showingZenPanel = false
    @State private var selectedView = ConnectionViewTabID.terminal
    @State private var selectedTerminalTabId: UUID? = Self.tabId
    @State private var selectedFileTabId: UUID?
    @State private var terminalView: GhosttyTerminalView?
    @State private var terminalReady = false
    @State private var voicePresentation = TerminalVoicePresentationState.idle
    @State private var showsFloatingControl = true
    @State private var floatingControlPreferences: TerminalFloatingControlPreferences

    init(
        tabManager: TerminalTabManager,
        voiceInputRuntimeStore: VoiceInputRuntimeStore
    ) {
        self.tabManager = tabManager
        self.voiceInputRuntimeStore = voiceInputRuntimeStore
        _keyboardCoordinator = ObservedObject(
            wrappedValue: tabManager.keyboardCoordinator
        )
        _floatingVoiceOperation = ObservedObject(
            wrappedValue: voiceInputRuntimeStore.runtime(for: Self.tabId).recordingOperation
        )
        _floatingControlPreferences = State(
            initialValue: Self.initialFloatingControlPreferences
        )
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
                        ZStack {
                            floatingInputControl
                            zenModeOverlay
                                .zIndex(1)
                        }
                    }
                }
                .navigationTitle("Test Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if testsViewPicker {
                        if #available(iOS 27.1, *) {
                            ConnectionViewPickerToolbar(selection: $selectedView, tabs: ConnectionViewTabID.allCases)
                        } else {
                            ToolbarItem(placement: .principal) {
                                ConnectionViewSegmentedPicker(selection: $selectedView, tabs: ConnectionViewTabID.allCases)
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Chrome") {}
                            .accessibilityIdentifier("vvterm.zenTest.chrome")
                    }

                    if #available(iOS 27.1, *), testsViewPicker {
                        AdaptiveActionsToolbar { testToolbarActions }
                    } else {
                        ToolbarItemGroup(placement: .navigationBarTrailing) { testToolbarActions }
                    }
                }
                .toolbar(isZenModeEnabled ? .hidden : .visible, for: .navigationBar)
                .toolbar(isZenModeEnabled ? .hidden : .automatic, for: .bottomBar)
                .overlay(alignment: .bottomLeading) {
                    if testsViewPicker {
                        ViewPickerDiagnostics(selection: selectedView)
                            .allowsHitTesting(false)
                    }
                }
        }
        .task {
            ghosttyApp.startIfNeeded()
        }
        .onChange(of: terminalReady) { isReady in
            if isReady, simulatesKeyboardFrames {
                configureTerminalTest()
            }
        }
    }

    @ViewBuilder
    private var testToolbarActions: some View {
        if testsViewPicker {
            Button {} label: { Image(systemName: "plus") }
                .accessibilityIdentifier("vvterm.viewPickerTest.add")
        }
        Menu {
            sessionActions(style: .menu)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("vvterm.terminal.moreMenu")
    }

    private var simulatesKeyboardFrames: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-simulate-keyboard-frames"
        )
    }

    private var testsViewPicker: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-view-picker")
    }

    private func configureTerminalTest() {
        guard let terminalView else { return }
        if tabManager.sessionState.paneState(for: Self.paneId) == nil {
            tabManager.sessionState.setPaneState(
                TerminalPaneState(
                    paneId: Self.paneId,
                    tabId: Self.tabId,
                    serverId: Self.server.id
                )
            )
        }
        tabManager.registerTerminalSurface(terminalView, for: Self.paneId)
        tabManager.updatePaneState(Self.paneId, connectionState: .connected)
        keyboardCoordinator.setActivePane(Self.paneId)
        keyboardCoordinator.setViewActive(true)
    }

    private func exitZenMode() {
        showingZenPanel = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isZenModeEnabled = false
        }
    }

    private func sessionActions(style: TerminalSessionMenuActions.Style) -> TerminalSessionMenuActions {
        TerminalSessionMenuActions(
            style: style, isTerminalSelected: selectedView == .terminal,
            zenMode: isZenModeEnabled ? .active : .inactive,
            composer: tabManager.richPasteRuntimeStore.runtime(for: Self.paneId, tabManager: tabManager).composer,
            canOpenSessions: true,
            canDisconnect: true,
            perform: { command in
                showingZenPanel = false
                switch command {
                case .find: terminalView?.showFindNavigator()
                case .keyboard: keyboardCoordinator.userRequestedKeyboardCommand()
                case .toggleZen:
                    if isZenModeEnabled { exitZenMode() } else { isZenModeEnabled = true }
                case .sessions, .settings, .disconnect: break
                }
            }
        )
    }

    private var zenModeOverlay: some View {
        ZenModeFloatingOverlay(isPanelPresented: $showingZenPanel) { width in
            IOSZenModePanel(
                width: width,
                server: Self.server,
                selectedView: selectedView,
                selectedViewBinding: $selectedView,
                viewTabs: [.terminal, .files],
                terminalTabs: [Self.terminalTab],
                selectedTerminalTabId: $selectedTerminalTabId,
                terminalTabTitle: { _ in "Test Terminal" },
                paneState: { _ in nil },
                onCloseTerminalTab: { _ in },
                fileTabs: [],
                selectedFileTabId: $selectedFileTabId,
                fileTabTitle: { _ in "Test Files" },
                onSelectFileTab: { _ in },
                onCloseFileTab: { _ in },
                floatingControlCanBeShown: true,
                floatingControlIsShown: $showsFloatingControl,
                onNewTerminalTab: {},
                onNewFileTab: {},
                sessionActions: sessionActions(style: .zen),
                onBack: {}

            )
        }
    }

    @ViewBuilder
    private var floatingInputControl: some View {
        switch floatingControlPresentation {
        case .hidden:
            EmptyView()
        case .visible(let style):
            let runtime = voiceInputRuntimeStore.runtime(for: Self.tabId)
            TerminalFloatingInputControl(
                style: style,
                preferences: floatingControlPreferences,
                hasProAccess: false,
                voiceEnabled: true,
                terminalIsReady: terminalReady,
                phase: floatingInputPhase,
                audioService: runtime.audioService,
                onVoiceToggle: toggleVoiceTest,
                onCancelVoice: cancelVoiceTest,
                onShowKeyboard: showKeyboardTest,
                onSendReturn: sendReturnFromVoiceTest,
                onSystemAction: { action in
                    _ = terminalView?.performAccessorySystemAction(action)
                },
                onMove: { horizontalFraction, verticalFraction in
                    floatingControlPreferences.hiddenSide = nil
                    floatingControlPreferences.horizontalFraction = horizontalFraction
                    floatingControlPreferences.verticalFraction = verticalFraction
                    floatingControlPreferences = floatingControlPreferences.normalized()
                },
                onHide: { side, verticalFraction in
                    floatingControlPreferences.hiddenSide = side
                    floatingControlPreferences.verticalFraction = verticalFraction
                    floatingControlPreferences = floatingControlPreferences.normalized()
                },
                onShow: {
                    if let hiddenSide = floatingControlPreferences.hiddenSide {
                        floatingControlPreferences.horizontalFraction =
                            hiddenSide.restoredHorizontalFraction
                    }
                    floatingControlPreferences.hiddenSide = nil
                },
                onResetPosition: {
                    floatingControlPreferences.hiddenSide = nil
                    floatingControlPreferences.horizontalFraction =
                        TerminalFloatingControlPreferences.defaultHorizontalFraction
                    floatingControlPreferences.verticalFraction =
                        TerminalFloatingControlPreferences.defaultVerticalFraction
                }
            )
        }
    }

    private var floatingControlPresentation:
        TerminalFloatingControlPresentationPolicy.Presentation {
        TerminalFloatingControlPresentationPolicy.presentation(
            for: .init(
                isTerminalSelected: selectedView == .terminal,
                hasFocusedPane: terminalReady,
                keyboardIsUserHidden: keyboardCoordinator.isUserHidden,
                isSoftwareKeyboardVisible: keyboardCoordinator.isSoftwareKeyboardVisible,
                findNavigatorIsVisible: false,
                isZenModeEnabled: isZenModeEnabled,
                isFloatingControlShownInZen: showsFloatingControl,
                preferences: floatingControlPreferences,
                hasProAccess: false,
                inputPhase: floatingInputPhase
            )
        )
    }

    private var floatingInputPhase: TerminalFloatingInputPhase {
        TerminalFloatingInputPhase(
            voiceOperationPhase: floatingVoiceOperation.phase,
            voicePresentation: voicePresentation
        )
    }

    private func showKeyboardTest() {
        keyboardCoordinator.userRequestedShow()
        guard simulatesKeyboardFrames,
              let screenBounds = terminalView?.window?.screen.bounds else {
            return
        }
        let height = min(360, screenBounds.height * 0.38)
        keyboardCoordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
            CGRect(
                x: screenBounds.minX,
                y: screenBounds.maxY - height,
                width: screenBounds.width,
                height: height
            )
        )
    }

    private func toggleVoiceTest() {
        if voicePresentation.isRecording {
            finishVoiceTest()
        } else {
            startVoiceTest()
        }
    }

    private func startVoiceTest() {
        let operation = voiceInputRuntimeStore.runtime(for: Self.tabId)
            .recordingOperation
        operation.startRecording(
            operation: { _ in },
            onStarted: {
                voicePresentation = .recording(.floatingControl)
            },
            onFailure: { _ in
                voicePresentation = .idle
            }
        )
    }

    private func finishVoiceTest() {
        let operation = voiceInputRuntimeStore.runtime(for: Self.tabId)
            .recordingOperation
        _ = operation.startProcessing(
            operation: { _ in "test transcript" },
            onSuccess: { _ in
                voicePresentation = .pendingReturn
            },
            onFailure: { _ in
                voicePresentation = .idle
            }
        )
    }

    private func cancelVoiceTest() {
        voiceInputRuntimeStore.runtime(for: Self.tabId).cancel()
        voicePresentation = .idle
    }

    private func sendReturnFromVoiceTest() {
        guard terminalView?.sendReturnKey() == true else { return }
        voicePresentation = .idle
    }
}

private struct ViewPickerDiagnostics: View {
    let selection: ConnectionViewTabID

    var body: some View {
        if #available(iOS 27.1, *) {
            AxisDiagnostics(selection: selection)
        } else {
            Text("horizontal \(selection.rawValue)")
                .accessibilityIdentifier("vvterm.viewPickerTest.selection")
        }
    }

    @available(iOS 27.1, *)
    private struct AxisDiagnostics: View {
        let selection: ConnectionViewTabID
        @Environment(\.toolbarVerticalEdge) private var edge

        var body: some View {
            Text("\(edge == nil ? "horizontal" : "vertical") \(selection.rawValue)")
                .accessibilityIdentifier("vvterm.viewPickerTest.selection")
        }
    }
}
#endif
