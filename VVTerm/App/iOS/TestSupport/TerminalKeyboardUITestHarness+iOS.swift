#if os(iOS) && DEBUG
import Combine
import SwiftUI
import UIKit

struct TerminalKeyboardUITestHarness: View {
    private final class MetadataChurnCounter: ObservableObject {
        private(set) var value = 0

        func next() -> Int {
            guard value < Int.max else { return value }
            value += 1
            return value
        }
    }

    private static let paneId = UUID(uuidString: "B54F29D8-7C3E-4DB8-B3D7-9D9F1604B755")!
    private static let clearTerminalBackgroundCacheForUITest: Void = {
        guard Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-clear-terminal-background-cache"
        ) else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "terminalBackgroundColor")
    }()
    private static let codexTUIResponse = Data(
        "\u{1B}[?1049h\u{1B}[?2004h\u{1B}[?1004h\u{1B}]0;Codex\u{07}\u{1B}[2J\u{1B}[HCodex response\r\n\u{1B}[?25h".utf8
    )
    private static let mouseCaptureSequence = Data(
        "\u{1B}[?1000h\u{1B}[?1006h".utf8
    )
    private static let touchSelectionFixture = Data(
        (
            (0..<40)
                .map { "VVTerm local selection fixture \($0)" }
                .joined(separator: "\r\n") + "\r\n"
        ).utf8
    )

    init(tabManager: TerminalTabManager) {
        self.tabManager = tabManager
        _keyboardCoordinator = ObservedObject(
            wrappedValue: tabManager.keyboardCoordinator
        )
        _presentationState = ObservedObject(
            wrappedValue: tabManager.presentationState
        )
        _ = Self.clearTerminalBackgroundCacheForUITest
    }

    private enum LifecycleStatus: String {
        case initial
        case connected
        case inactive
        case background
    }

    private enum SimulatedKeyboardGeometry {
        case docked
        case floating
        case hidden
    }

    private enum KeyboardAccessoryPairingObservation {
        case idle
        case observing(accessoryOnlyObserved: Bool)
        case completed(accessoryOnlyObserved: Bool)

        var status: String {
            switch self {
            case .idle:
                "idle"
            case .observing:
                "observing"
            case .completed:
                "completed"
            }
        }

        var observedAccessoryOnly: Bool {
            switch self {
            case .idle:
                false
            case .observing(let accessoryOnlyObserved),
                 .completed(let accessoryOnlyObserved):
                accessoryOnlyObserved
            }
        }
    }

    @EnvironmentObject private var ghosttyApp: GhosttyRuntime
    @EnvironmentObject private var appLockManager: AppLockManager
    private let tabManager: TerminalTabManager
    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @ObservedObject private var presentationState: TerminalPresentationStateStore
    @AppStorage(PrivacyModeSettings.enabledKey) private var privacyModeEnabled = false
    @State private var terminalView: GhosttyTerminalView?
    @State private var terminalReady = false
    @State private var showsTerminal = true
    @State private var showingSettings = false
    @State private var simulatesPrivacyShield = false
    @State private var focusRequestID = 0
    @State private var keyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardFrame: CGRect?
    @State private var keyboardShowTransitionCount = 0
    @State private var keyboardHideTransitionCount = 0
    @State private var foreignKeyboardFrameInjectionCount = 0
    @State private var keyboardAccessoryPairingObservation = KeyboardAccessoryPairingObservation.idle
    @State private var diagnostics = "notReady"
    @State private var lifecycleStatus = LifecycleStatus.initial
    @State private var receivedInputHex = "none"
    @State private var receivedInput = Data()
    @State private var returnInputCount = 0
    @State private var codexResponseCount = 0
    @State private var zoomActionCount = 0
    @State private var lastZoomAction = "none"
    @State private var paneShortcutActionCount = 0
    @State private var lastPaneShortcutAction = "none"
    @State private var paneFocusActionCount = 0
    @StateObject private var terminalMetadataChurn = MetadataChurnCounter()
    @State private var showingPaneCloseConfirmation = false
    @State private var lastPaneCloseDialogAction = "none"
    @Environment(\.scenePhase) private var scenePhase

    private var preservesTerminalSize: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-preserve-terminal-size")
    }

    private var simulatesKeyboardFrames: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-simulate-keyboard-frames")
    }

    private var simulatesCodexTUIResponse: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-codex-tui-response")
    }

    private var simulatesTerminalMouseCapture: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-mouse-capture")
    }

    private var seedsTerminalSelectionFixture: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-selection-fixture")
    }

    private var seedsTerminalPasteboard: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-terminal-pasteboard")
    }

    private var testsAppShortcutInputs: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-terminal-app-shortcut-inputs"
        )
    }

    private var simulatesTerminalMetadataChurn: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-terminal-metadata-churn"
        )
    }

    private var voicePresentation: TerminalVoicePresentationState {
        presentationState.voicePresentation(for: Self.paneId)
    }

    private var simulatesStaleLightAccessoryCacheOnResume: Bool {
        Foundation.ProcessInfo.processInfo.arguments.contains(
            "--vvterm-ui-test-stale-light-accessory-cache-on-resume"
        )
    }

    private let diagnosticTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsTerminal {
                TerminalKeyboardHarnessRepresentable(
                    tabManager: tabManager,
                    terminalView: $terminalView,
                    terminalReady: $terminalReady,
                    focusRequestID: focusRequestID,
                    paneId: Self.paneId,
                    onInput: { data in
                        receivedInputHex = data.map { String(format: "%02x", $0) }.joined()
                        receivedInput.append(data)
                        if data.contains(0x0D) {
                            returnInputCount += 1
                        }
                        if simulatesCodexTUIResponse, data.contains(0x0D), codexResponseCount == 0 {
                            DispatchQueue.main.async {
                                terminalView?.feedData(Self.codexTUIResponse)
                                codexResponseCount += 1
                            }
                        }
                    },
                    onZoomAction: { action in
                        zoomActionCount += 1
                        switch action {
                        case .zoomIn:
                            lastZoomAction = "zoomIn"
                        case .zoomOut:
                            lastZoomAction = "zoomOut"
                        case .reset:
                            lastZoomAction = "reset"
                        }
                    },
                    onPaneKeyboardShortcut: { action in
                        paneShortcutActionCount += 1
                        lastPaneShortcutAction = String(describing: action)
                        if action == .closeFocusedPane {
                            requestPaneCloseConfirmation()
                        }
                    },
                    onPaneFocus: {
                        paneFocusActionCount += 1
                    }
                )
                .terminalKeyboardAvoidance(
                    focusedPaneId: Self.paneId,
                    paneIds: [Self.paneId],
                    terminalSurfaceChange: terminalView.map {
                        .registered(
                            paneId: Self.paneId,
                            surfaceIdentity: ObjectIdentifier($0)
                        )
                    },
                    terminalProvider: { _ in terminalView },
                    keyboardCoordinator: keyboardCoordinator,
                    enabledOverride: preservesTerminalSize
                )
                .ignoresSafeArea(.container)
                .accessibilityIdentifier("vvterm.keyboardTest.container")
            } else {
                nonTerminalSurface
            }

            if simulatesPrivacyShield {
                Color.black
                    .opacity(0.55)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("vvterm.keyboardTest.privacyShield")
            }

            if keyboardCoordinator.isUserHidden {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button("Keyboard") {
                            requestSoftwareKeyboard()
                        }
                        .accessibilityIdentifier("vvterm.terminal.floating.keyboard")

                        if !voicePresentation.isRecording {
                            Button("Voice input") {
                                presentationState.applyVoiceEvent(
                                    .recordingStarted,
                                    for: Self.paneId
                                )
                            }
                            .accessibilityIdentifier("vvterm.terminal.floating.voiceInput")
                        }

                        if voicePresentation.isPendingReturn {
                            Button("Enter") {
                                presentationState.applyVoiceEvent(
                                    .pendingReturnDismissed,
                                    for: Self.paneId
                                )
                            }
                            .accessibilityIdentifier("vvterm.terminal.floating.return")
                        }

                        if voicePresentation.isRecording {
                            Button("Finish voice test") {
                                presentationState.applyVoiceEvent(
                                    .transcriptionSent,
                                    for: Self.paneId
                                )
                            }
                            .accessibilityIdentifier("vvterm.keyboardTest.voice.transcriptionSent")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(terminalReady ? "ready=true" : "ready=false")
                    .accessibilityIdentifier("vvterm.keyboardTest.ready")
                Text(diagnostics)
                    .accessibilityIdentifier("vvterm.keyboardTest.diagnostics")
                    .lineLimit(6)
            }
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.72))
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Terminal") {
                        terminalReady = false
                        showsTerminal = true
                        focusRequestID += 1
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.mode.terminal")

                    Button("Other") {
                        terminalView?.releaseTerminalInput()
                        terminalView = nil
                        terminalReady = false
                        showsTerminal = false
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.mode.other")

                    Button("Hide") {
                        terminalView?.dismissKeyboardFromToolbar()
                        if simulatesKeyboardFrames {
                            applySimulatedKeyboardGeometry(.hidden)
                        }
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hideViaToolbar")

                    Button("Keyboard") {
                        requestSoftwareKeyboard()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.showKeyboard")

                    Menu {
                        Button("Settings") {
                            presentSettings()
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.menu.settings")

                        Button("Find") {
                            showFindInput()
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.menu.find")

                        Button("Keyboard") {
                            requestSoftwareKeyboard()
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.menu.showKeyboard")
                    } label: {
                        Text("More")
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.menu")

                    Button("Close Alert") {
                        requestPaneCloseConfirmation()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.closeAlert")

                }

                HStack(spacing: 8) {
                    Button("Mark") {
                        terminalView?.keyboardUITestSetMarkedText("nihon")
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.ime.mark")

                    Button("Del") {
                        terminalView?.keyboardUITestDeleteBackwardThroughIMEProxy()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.ime.delete")

                    Button("Commit") {
                        terminalView?.keyboardUITestCommitMarkedText()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.ime.commit")

                    Button("Hardware") {
                        terminalView?.keyboardUITestRequestHardwareKeyboardFocus()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardwareFocus")

                    Button("HW On") {
                        terminalView?.keyboardUITestSetHardwareKeyboardAttached(true)
                        if simulatesKeyboardFrames,
                           terminalView?.keyboardCoordinatorDiagnosticSnapshot()
                            .isSoftwareKeyboardSuppressed == true {
                            applySimulatedKeyboardGeometry(.hidden)
                        }
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardware.attach")

                    Button("HW Off") {
                        terminalView?.keyboardUITestSetHardwareKeyboardAttached(false)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardware.detach")

                    Button("Lose Keyboard") {
                        terminalView?.keyboardUITestBeginUnexpectedSoftwareKeyboardLoss()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.keyboard.unexpectedLoss")
                }

                HStack(spacing: 8) {
                    Button("Repeat h") {
                        terminalView?.keyboardUITestBeginLayoutResolvedHardwareKeyRepeat(
                            text: "h",
                            shifted: false
                        )
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardwareRepeat.begin.h")

                    Button("Repeat H") {
                        terminalView?.keyboardUITestBeginLayoutResolvedHardwareKeyRepeat(
                            text: "H",
                            shifted: true
                        )
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardwareRepeat.begin.shiftH")

                    Button("Repeat Tick") {
                        terminalView?.keyboardUITestFireHardwareKeyRepeat()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardwareRepeat.tick")

                    Button("Repeat Release") {
                        terminalView?.keyboardUITestEndHardwareKeyRepeat()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardwareRepeat.release")

                    Button("Repeat Cancel") {
                        terminalView?.keyboardUITestCancelHardwareKeyRepeat()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.hardwareRepeat.cancel")
                }

                if testsAppShortcutInputs {
                    HStack(spacing: 8) {
                        Button("Software Cmd-D") {
                            terminalView?.keyboardUITestSendSoftwareShortcut(
                                "d",
                                modifiers: .init(command: true)
                            )
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.shortcut.software.cmdD")

                        Button("Software Cmd-Shift-D") {
                            terminalView?.keyboardUITestSendSoftwareShortcut(
                                "D",
                                modifiers: .init(command: true)
                            )
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.shortcut.software.cmdShiftD")

                        Button("Software Cmd-W") {
                            terminalView?.keyboardUITestSendSoftwareShortcut(
                                "w",
                                modifiers: .init(command: true)
                            )
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.shortcut.software.cmdW")

                        Button("Toolbar Cmd-Alt-Left") {
                            terminalView?.keyboardUITestSendToolbarShortcut(
                                .arrowLeft,
                                modifiers: .init(alternate: true, command: true)
                            )
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.shortcut.toolbar.cmdAltLeft")

                        Button("Custom Cmd-Ctrl-Right") {
                            terminalView?.keyboardUITestSendCustomShortcut(
                                .arrowRight,
                                modifiers: .init(control: true, command: true)
                            )
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.shortcut.custom.cmdCtrlRight")

                        Button("Custom Ctrl-X") {
                            terminalView?.keyboardUITestSendCustomShortcut(
                                .x,
                                modifiers: .init(control: true)
                            )
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.shortcut.custom.ctrlX")
                    }
                }

                Button("Cursor Bottom") {
                    terminalView?.keyboardUITestMoveCursorToBottom()
                }
                .accessibilityIdentifier("vvterm.keyboardTest.cursor.bottom")

                HStack(spacing: 8) {
                    Button("Other App") {
                        lifecycleStatus = .inactive
                        applyRouteActivation(
                            .foregroundInactive,
                            windowOwnership: .notKey
                        )
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.window.notKey")

                    Button("VVTerm") {
                        lifecycleStatus = .connected
                        applyRouteActivation(
                            .foregroundActive,
                            windowOwnership: .key
                        )
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.window.key")

                    Button("Docked") {
                        applySimulatedKeyboardGeometry(.docked)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.geometry.docked")

                    Button("Floating") {
                        applySimulatedKeyboardGeometry(.floating)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.geometry.floating")

                    Button("No Frame") {
                        applySimulatedKeyboardGeometry(.hidden)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.geometry.hidden")

                    Button("Foreign KB") {
                        simulateSameScreenForeignKeyboardFrame()
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.geometry.foreignDocked")
                }

                HStack(spacing: 8) {
                    Button("Inactive") {
                        lifecycleStatus = .inactive
                        applyRouteActivation(.foregroundInactive)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.scene.inactive")

                    Button("Active") {
                        lifecycleStatus = .connected
                        applyRouteActivation(.foregroundActive)
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.scene.active")

                    Button("Shield") {
                        handleSceneWillDeactivate(
                            Notification(
                                name: UIScene.willDeactivateNotification,
                                object: terminalView?.window?.windowScene
                            )
                        )
                        simulatesPrivacyShield = true
                        lifecycleStatus = .inactive
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.privacy.shield")

                    Button("Resume") {
                        if simulatesStaleLightAccessoryCacheOnResume {
                            UserDefaults.standard.set(
                                "#ffffff",
                                forKey: "terminalBackgroundColor"
                            )
                        }
                        simulatesPrivacyShield = false
                        lifecycleStatus = .inactive
                        applyRouteActivation(.foregroundInactive)
                        // Face ID removes the lock gate before UIKit finishes
                        // returning the terminal scene to foreground-active.
                        // Reproduce that ordering before the final recovery.
                        DispatchQueue.main.async {
                            lifecycleStatus = .connected
                            applyRouteActivation(.foregroundActive)
                            terminalView?.resumeRendering()
                            tabManager.keyboardCoordinator
                                .activeTerminalContentDidBecomeVisible(for: Self.paneId)
                        }
                    }
                    .accessibilityIdentifier("vvterm.keyboardTest.privacy.resume")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .topTrailing)
            .padding(8)
        }
        .background(Color.black)
        .terminalCloseConfirmationAlert(
            isPresented: $showingPaneCloseConfirmation,
            message: String(localized: "The SSH connection will be terminated."),
            onCancel: {
                lastPaneCloseDialogAction = "cancel"
            },
            onClose: {
                lastPaneCloseDialogAction = "close"
            }
        )
        .onChange(of: showingPaneCloseConfirmation) { _ in
            applyRouteActivation(.foregroundActive)
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            applyRouteActivation(.foregroundActive)
        }) {
            NavigationStack {
                List {
                    Section("Terminal") {
                        Text("Keyboard settings")
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") {
                            showingSettings = false
                        }
                        .accessibilityIdentifier("vvterm.keyboardTest.settings.close")
                    }
                }
            }
            .accessibilityIdentifier("vvterm.keyboardTest.settings.sheet")
        }
        .task {
            ghosttyApp.startIfNeeded()
        }
        .onChange(of: terminalReady) { isReady in
            guard isReady else { return }
            configureLifecycleHarness()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if lifecycleStatus == .background {
                    resumeLifecycleHarnessAfterForeground()
                } else {
                    lifecycleStatus = .connected
                    applyRouteActivation(.foregroundActive)
                }
            case .inactive:
                if lifecycleStatus != .background {
                    lifecycleStatus = .inactive
                }
                applyRouteActivation(.foregroundInactive)
            case .background:
                lifecycleStatus = .background
                applyRouteActivation(.background)
            @unknown default:
                lifecycleStatus = .background
                applyRouteActivation(.background)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
            handleSceneWillDeactivate(notification)
        }
        .onReceive(diagnosticTimer) { _ in
            if simulatesTerminalMetadataChurn {
                let updateCount = terminalMetadataChurn.next()
                tabManager.updatePaneTitle(
                    Self.paneId,
                    rawTitle: "Metadata \(updateCount)"
                )
                tabManager.updatePaneWorkingDirectory(
                    Self.paneId,
                    rawDirectory: "/tmp/metadata-\(updateCount)"
                )
            }
            refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            noteKeyboardFrame(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            noteKeyboardFrame(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            noteKeyboardHidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            noteKeyboardHidden()
        }
    }

    private var nonTerminalSurface: some View {
        Button("Other Surface") { }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.08))
            .accessibilityIdentifier("vvterm.keyboardTest.nonTerminalSurface")
    }

    private func noteKeyboardFrame(_ note: Notification) {
        guard !simulatesKeyboardFrames else { return }
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }
        let screenBounds = terminalView?.window?.screen.bounds ?? UIScreen.main.bounds
        let overlap = screenBounds.intersection(frame)
        let height = overlap.isNull ? 0 : overlap.height
        let visible = height >= 100
        if visible != keyboardVisible {
            if visible {
                keyboardShowTransitionCount += 1
            } else {
                keyboardHideTransitionCount += 1
            }
        }
        keyboardHeight = visible ? height : 0
        keyboardVisible = visible
        keyboardFrame = visible ? frame : nil
        refreshDiagnostics()
    }

    private func noteKeyboardHidden() {
        guard !simulatesKeyboardFrames else { return }
        if keyboardVisible {
            keyboardHideTransitionCount += 1
        }
        keyboardVisible = false
        keyboardHeight = 0
        keyboardFrame = nil
        refreshDiagnostics()
    }

    private func refreshDiagnostics() {
        guard let terminalView else {
            diagnostics = "notReady ghostty=\(ghosttyApp.readiness.rawValue)"
            return
        }
        let terminalDiagnostics = terminalView.keyboardUITestDiagnostics(
            keyboardVisible: keyboardVisible,
            keyboardHeight: keyboardHeight
        )
        observeKeyboardAccessoryPairing(terminalDiagnostics: terminalDiagnostics)
        let primaryMousePresses = mouseReportCount(buttonPattern: "0", terminator: "M")
        let primaryMouseReleases = mouseReportCount(buttonPattern: "0", terminator: "m")
        let mouseScrollReports = mouseReportCount(buttonPattern: "6[45]", terminator: "M")
        let lowercaseHInputs = inputByteCount(0x68)
        let uppercaseHInputs = inputByteCount(0x48)
        diagnostics = terminalDiagnostics + " " + keyboardAvoidanceDiagnostics(for: terminalView)
            + " keyboardPresentation=\(keyboardPresentationDescription)"
            + " cachedTerminalBackground=\(UserDefaults.standard.string(forKey: "terminalBackgroundColor") ?? "none")"
            + " userHidden=\(keyboardCoordinator.isUserHidden)"
            + " keyboardShows=\(keyboardShowTransitionCount) keyboardHides=\(keyboardHideTransitionCount)"
            + " foreignKeyboardFrames=\(foreignKeyboardFrameInjectionCount)"
            + " accessoryPairingObservation=\(keyboardAccessoryPairingObservation.status)"
            + " orphanAccessoryObserved=\(keyboardAccessoryPairingObservation.observedAccessoryOnly)"
            + " reconnect=\(lifecycleStatus.rawValue) inputHex=\(receivedInputHex)"
            + " returnInputs=\(returnInputCount) codexResponses=\(codexResponseCount)"
            + " findPresented=\(terminalView.isFindNavigatorVisible)"
            + " mouseCaptured=\(terminalView.surface?.mouseCaptured == true)"
            + " primaryMousePresses=\(primaryMousePresses) primaryMouseReleases=\(primaryMouseReleases)"
            + " mouseScrollReports=\(mouseScrollReports) zoomActions=\(zoomActionCount)"
            + " lastZoomAction=\(lastZoomAction)"
            + " paneShortcutActions=\(paneShortcutActionCount)"
            + " lastPaneShortcutAction=\(lastPaneShortcutAction)"
            + " paneFocusActions=\(paneFocusActionCount)"
            + " lastPaneCloseDialogAction=\(lastPaneCloseDialogAction)"
            + " lowercaseHInputs=\(lowercaseHInputs) uppercaseHInputs=\(uppercaseHInputs)"
    }

    private func inputByteCount(_ byte: UInt8) -> Int {
        receivedInput.reduce(into: 0) { count, receivedByte in
            if receivedByte == byte {
                count += 1
            }
        }
    }

    private func mouseReportCount(buttonPattern: String, terminator: Character) -> Int {
        let reports = String(decoding: receivedInput, as: UTF8.self)
        let pattern = "\u{1B}\\[<\(buttonPattern);[0-9]+;[0-9]+\(terminator)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return expression.numberOfMatches(
            in: reports,
            range: NSRange(reports.startIndex..<reports.endIndex, in: reports)
        )
    }

    private func observeKeyboardAccessoryPairing(terminalDiagnostics: String) {
        guard case .observing(let accessoryOnlyObserved) = keyboardAccessoryPairingObservation else {
            return
        }

        let accessoryAttached = terminalDiagnostics.contains("accessoryAttached=true")
        let observedAccessoryOnly = accessoryOnlyObserved || (accessoryAttached && !keyboardVisible)
        if keyboardVisible, accessoryAttached {
            keyboardAccessoryPairingObservation = .completed(
                accessoryOnlyObserved: observedAccessoryOnly
            )
            return
        }

        keyboardAccessoryPairingObservation = .observing(
            accessoryOnlyObserved: observedAccessoryOnly
        )
    }

    private func configureLifecycleHarness() {
        guard let terminalView else { return }
        let manager = tabManager
        if manager.sessionState.paneState(for: Self.paneId) == nil {
            let tab = TerminalTab(serverId: UUID(), title: "Keyboard lifecycle test")
            manager.sessionState.setPaneState(TerminalPaneState(
                paneId: Self.paneId,
                tabId: tab.id,
                serverId: tab.serverId
            ))
        }
        manager.registerTerminalSurface(terminalView, for: Self.paneId)
        manager.updatePaneState(Self.paneId, connectionState: .connected)
        manager.keyboardCoordinator.setActivePane(Self.paneId)
        manager.keyboardCoordinator.setViewActive(true)
        if seedsTerminalSelectionFixture || simulatesTerminalMouseCapture {
            terminalView.feedData(Self.touchSelectionFixture)
        }
        if simulatesTerminalMouseCapture {
            terminalView.feedData(Self.mouseCaptureSequence)
        }
        if seedsTerminalPasteboard {
            UIPasteboard.general.string = "touch-paste"
        }
        lifecycleStatus = .connected
    }

    private func requestSoftwareKeyboard() {
        keyboardAccessoryPairingObservation = .observing(
            accessoryOnlyObserved: false
        )
        tabManager.keyboardCoordinator.userRequestedShow()
        terminalView?.dismissFindNavigator()
    }

    private func presentSettings() {
        tabManager.keyboardCoordinator
            .deactivateInputImmediately(reason: .routeModal)
        showingSettings = true
    }

    private func requestPaneCloseConfirmation() {
        tabManager.keyboardCoordinator
            .deactivateInputImmediately(reason: .routeModal)
        showingPaneCloseConfirmation = true
    }

    private func showFindInput() {
        terminalView?.showFindNavigator()
    }

    private func applyRouteActivation(
        _ sceneActivation: TerminalKeyboardRouteActivationPolicy.SceneActivation,
        windowOwnership: TerminalKeyboardRouteActivationPolicy.WindowOwnership = .unknown,
        contentObscured: Bool = false
    ) {
        let manager = tabManager
        let presentationOwnership: TerminalKeyboardRouteActivationPolicy.PresentationOwnership =
            showingSettings || showingPaneCloseConfirmation ? .routeModal : .terminal
        switch TerminalKeyboardRouteActivationPolicy.effect(
            routeVisible: true,
            terminalSelected: showsTerminal,
            sceneActivation: sceneActivation,
            windowOwnership: windowOwnership,
            presentationOwnership: presentationOwnership,
            contentObscured: contentObscured
        ) {
        case .activate:
            manager.keyboardCoordinator.setActivePane(Self.paneId)
            manager.keyboardCoordinator.setViewActive(true)
            manager.keyboardCoordinator.activeTerminalSceneDidActivate(for: Self.paneId)
        case .suspend:
            manager.keyboardCoordinator.activeTerminalSceneWillDeactivate(for: Self.paneId)
        case .deactivate:
            if contentObscured {
                manager.keyboardCoordinator.deactivateInputImmediately()
            } else if presentationOwnership == .routeModal {
                manager.keyboardCoordinator.deactivateInputImmediately(reason: .routeModal)
            } else {
                manager.keyboardCoordinator.setViewActive(false)
                manager.keyboardCoordinator.setActivePane(nil)
            }
        }
    }

    private func applySimulatedKeyboardGeometry(_ geometry: SimulatedKeyboardGeometry) {
        guard let screenBounds = terminalView?.window?.screen.bounds else { return }
        let frame: CGRect?
        switch geometry {
        case .docked:
            let height = min(360, screenBounds.height * 0.38)
            frame = CGRect(
                x: screenBounds.minX,
                y: screenBounds.maxY - height,
                width: screenBounds.width,
                height: height
            )
        case .floating:
            let width = min(320, screenBounds.width * 0.45)
            let height = min(260, screenBounds.height * 0.3)
            frame = CGRect(
                x: screenBounds.midX - width / 2,
                y: screenBounds.maxY - height - 100,
                width: width,
                height: height
            )
        case .hidden:
            frame = nil
        }

        let visible = frame != nil
        if visible != keyboardVisible {
            if visible {
                keyboardShowTransitionCount += 1
            } else {
                keyboardHideTransitionCount += 1
            }
        }
        keyboardVisible = visible
        keyboardHeight = frame?.height ?? 0
        keyboardFrame = frame
        if let frame {
            tabManager.keyboardCoordinator
                .keyboardUITestSetSoftwareKeyboardEndFrame(frame)
        } else {
            tabManager.keyboardCoordinator
                .keyboardUITestReceiveSoftwareKeyboardHidden()
        }
        refreshDiagnostics()
    }

    private func simulateSameScreenForeignKeyboardFrame() {
        guard let screenBounds = terminalView?.window?.screen.bounds else { return }
        let height = min(360, screenBounds.height * 0.38)
        let frame = CGRect(
            x: screenBounds.minX,
            y: screenBounds.maxY - height,
            width: screenBounds.width,
            height: height
        )
        tabManager.keyboardCoordinator
            .keyboardUITestReceiveKeyboardEndFrame(frame, isLocal: false)
        foreignKeyboardFrameInjectionCount += 1
        refreshDiagnostics()
    }

    private func handleSceneWillDeactivate(_ notification: Notification) {
        if let notifyingScene = notification.object as? UIScene,
           let terminalScene = terminalView?.window?.windowScene,
           notifyingScene !== terminalScene {
            return
        }

        terminalView?.pauseRendering(
            preservingForegroundKeyboardGrid: keyboardCoordinator.softwareKeyboardEndFrame != nil
        )

        if AppContentProtectionPolicy.shouldPrepareForSceneDeactivation(
            fullAppLockEnabled: appLockManager.fullAppLockEnabled,
            privacyModeEnabled: privacyModeEnabled,
            isAppLocked: appLockManager.isAppLocked
        ) {
            tabManager.keyboardCoordinator.deactivateInputImmediately()
        } else {
            applyRouteActivation(.foregroundInactive)
        }
    }

    private func resumeLifecycleHarnessAfterForeground() {
        guard terminalReady else { return }
        terminalView?.resumeRendering()
        tabManager.keyboardCoordinator.setActivePane(Self.paneId)
        tabManager.keyboardCoordinator.setViewActive(true)
        if simulatesKeyboardFrames {
            tabManager.keyboardCoordinator
                .keyboardUITestSetSoftwareKeyboardEndFrame(keyboardFrame)
        }
        tabManager.keyboardCoordinator.activeTerminalSceneDidActivate(
            for: Self.paneId
        )
        lifecycleStatus = .connected
    }

    private func keyboardAvoidanceDiagnostics(for terminal: GhosttyTerminalView) -> String {
        guard let window = terminal.window else {
            return "preserveSize=\(preservesTerminalSize) terminalTop=unavailable terminalBottom=unavailable cursorBottom=unavailable keyboardTop=unavailable"
        }

        let terminalFrame = terminal.convert(terminal.bounds, to: window)
        let visibleTerminalFrame = terminalFrame.intersection(window.bounds)
        let cursorFrame = terminal.convert(terminal.keyboardAvoidanceCursorRect(), to: window)
        let keyboardTop = keyboardFrame.map {
            window.convert($0, from: window.screen.coordinateSpace).minY
        }
        return [
            "preserveSize=\(preservesTerminalSize)",
            "terminalTop=\(metricText(terminalFrame.minY))",
            "terminalBottom=\(metricText(terminalFrame.maxY))",
            "terminalHeight=\(metricText(terminalFrame.height))",
            "visibleTerminalHeight=\(metricText(visibleTerminalFrame.isNull ? 0 : visibleTerminalFrame.height))",
            "cursorBottom=\(metricText(cursorFrame.maxY))",
            "keyboardTop=\(keyboardTop.map(metricText) ?? "none")"
        ].joined(separator: " ")
    }

    private var keyboardPresentationDescription: String {
        switch keyboardCoordinator.softwareKeyboardPresentation {
        case .hidden:
            return "hidden"
        case .docked:
            return "docked"
        case .floating:
            return "floating"
        }
    }

    private func metricText(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

struct TerminalSplitKeyboardUITestHarness: View {
    private static let firstPaneId = UUID(uuidString: "98B81AB0-ACF4-4555-A94D-399AE384C61E")!
    private static let secondPaneId = UUID(uuidString: "4405E542-FE33-4D06-9F8A-ABF93A0CFA8F")!

    @EnvironmentObject private var ghosttyApp: GhosttyRuntime
    private let tabManager: TerminalTabManager
    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @State private var firstTerminal: GhosttyTerminalView?
    @State private var secondTerminal: GhosttyTerminalView?
    @State private var firstReady = false
    @State private var secondReady = false
    @State private var focusedPaneId = Self.firstPaneId
    @State private var keyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var paneShortcutActionCount = 0
    @State private var lastPaneShortcutAction = "none"
    @State private var diagnostics = "notReady"

    private let diagnosticTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(tabManager: TerminalTabManager) {
        self.tabManager = tabManager
        _keyboardCoordinator = ObservedObject(
            wrappedValue: tabManager.keyboardCoordinator
        )
    }

    private var isReady: Bool {
        firstReady && secondReady
    }

    private var focusedTerminal: GhosttyTerminalView? {
        focusedPaneId == Self.firstPaneId ? firstTerminal : secondTerminal
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 1) {
                terminalSurface(
                    terminal: $firstTerminal,
                    ready: $firstReady,
                    paneId: Self.firstPaneId,
                    identifier: "vvterm.keyboardTest.terminalSurface.first",
                    label: "First Terminal Pane"
                )
                terminalSurface(
                    terminal: $secondTerminal,
                    ready: $secondReady,
                    paneId: Self.secondPaneId,
                    identifier: "vvterm.keyboardTest.terminalSurface.second",
                    label: "Second Terminal Pane"
                )
            }
            .background(.black)
            .terminalKeyboardAvoidance(
                focusedPaneId: focusedPaneId,
                paneIds: [Self.firstPaneId, Self.secondPaneId],
                terminalSurfaceChange: terminal(for: focusedPaneId).map {
                    .registered(
                        paneId: focusedPaneId,
                        surfaceIdentity: ObjectIdentifier($0)
                    )
                },
                terminalProvider: terminal(for:),
                keyboardCoordinator: keyboardCoordinator,
                enabledOverride: false
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(isReady ? "ready=true" : "ready=false")
                    .accessibilityIdentifier("vvterm.keyboardTest.ready")
                Text(diagnostics)
                    .accessibilityIdentifier("vvterm.keyboardTest.diagnostics")
                    .lineLimit(4)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.72))
            .allowsHitTesting(false)

            HStack {
                Spacer()
                Button("Pane A") {
                    focus(Self.firstPaneId)
                }
                .accessibilityIdentifier("vvterm.keyboardTest.focus.first")
                Button("Pane B") {
                    focus(Self.secondPaneId)
                }
                .accessibilityIdentifier("vvterm.keyboardTest.focus.second")
                Button("Keyboard") {
                    tabManager.keyboardCoordinator.userRequestedShow()
                }
                .accessibilityIdentifier("vvterm.keyboardTest.showKeyboard")
                Button("HW On") {
                    firstTerminal?.keyboardUITestSetHardwareKeyboardAttached(true)
                    secondTerminal?.keyboardUITestSetHardwareKeyboardAttached(true)
                }
                .accessibilityIdentifier("vvterm.keyboardTest.hardware.attach")
            }
            .buttonStyle(.borderedProminent)
            .padding(8)

            HStack(spacing: 8) {
                Button("Registered Cmd-D") {
                    focusedTerminal?.keyboardUITestSendRegisteredKeyCommand(
                        "d",
                        modifiers: .command
                    )
                }
                .accessibilityIdentifier("vvterm.keyboardTest.command.cmdD")

                Button("Registered Cmd-Alt-Left") {
                    focusedTerminal?.keyboardUITestSendRegisteredKeyCommand(
                        UIKeyCommand.inputLeftArrow,
                        modifiers: [.command, .alternate]
                    )
                }
                .accessibilityIdentifier("vvterm.keyboardTest.command.cmdAltLeft")

                Button("Registered Cmd-Ctrl-Right") {
                    focusedTerminal?.keyboardUITestSendRegisteredKeyCommand(
                        UIKeyCommand.inputRightArrow,
                        modifiers: [.command, .control]
                    )
                }
                .accessibilityIdentifier("vvterm.keyboardTest.command.cmdCtrlRight")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 52)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .task {
            ghosttyApp.startIfNeeded()
        }
        .onChange(of: firstReady) { _ in
            configureIfReady()
        }
        .onChange(of: secondReady) { _ in
            configureIfReady()
        }
        .onReceive(diagnosticTimer) { _ in
            refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) {
            noteKeyboardFrame($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            noteKeyboardFrame($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            noteKeyboardHidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            noteKeyboardHidden()
        }
    }

    private func terminalSurface(
        terminal: Binding<GhosttyTerminalView?>,
        ready: Binding<Bool>,
        paneId: UUID,
        identifier: String,
        label: String
    ) -> some View {
        TerminalKeyboardHarnessRepresentable(
            tabManager: tabManager,
            terminalView: terminal,
            terminalReady: ready,
            focusRequestID: 0,
            paneId: paneId,
            surfaceIdentifier: identifier,
            surfaceLabel: label,
            onInput: { _ in },
            onZoomAction: { _ in },
            onPaneKeyboardShortcut: { action in
                paneShortcutActionCount += 1
                lastPaneShortcutAction = String(describing: action)
            },
            onPaneFocus: {
                focus(paneId)
            }
        )
    }

    private func configureIfReady() {
        guard isReady, let firstTerminal, let secondTerminal else { return }
        let manager = tabManager
        for (paneId, terminal) in [
            (Self.firstPaneId, firstTerminal),
            (Self.secondPaneId, secondTerminal),
        ] {
            if manager.sessionState.paneState(for: paneId) == nil {
                let tab = TerminalTab(serverId: UUID(), title: "Split keyboard test")
                manager.sessionState.setPaneState(TerminalPaneState(
                    paneId: paneId,
                    tabId: tab.id,
                    serverId: tab.serverId
                ))
            }
            manager.registerTerminalSurface(terminal, for: paneId)
            manager.updatePaneState(paneId, connectionState: .connected)
        }
        focus(Self.firstPaneId)
        manager.keyboardCoordinator.setViewActive(true)
    }

    private func focus(_ paneId: UUID) {
        guard let firstTerminal, let secondTerminal else { return }
        focusedPaneId = paneId
        firstTerminal.acceptsTerminalInput = paneId == Self.firstPaneId
        secondTerminal.acceptsTerminalInput = paneId == Self.secondPaneId
        tabManager.keyboardCoordinator.setActivePane(paneId)
    }

    private func terminal(for paneId: UUID) -> GhosttyTerminalView? {
        paneId == Self.firstPaneId ? firstTerminal : secondTerminal
    }

    private func noteKeyboardFrame(_ note: Notification) {
        guard let terminal = focusedTerminal,
              let window = terminal.window,
              (note.object as? UIScreen).map({ $0 === window.screen }) != false,
              let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                .cgRectValue else {
            return
        }
        let overlap = window.screen.bounds.intersection(frame)
        keyboardHeight = overlap.isNull ? 0 : overlap.height
        keyboardVisible = keyboardHeight >= 100
    }

    private func noteKeyboardHidden() {
        keyboardVisible = false
        keyboardHeight = 0
    }

    private func refreshDiagnostics() {
        guard let focusedTerminal else {
            diagnostics = "notReady"
            return
        }
        let totalReloads = (firstTerminal?.keyboardUITestInputViewReloadCount ?? 0)
            + (secondTerminal?.keyboardUITestInputViewReloadCount ?? 0)
        let totalRebuilds = (firstTerminal?.keyboardUITestInputSessionRebuildCount ?? 0)
            + (secondTerminal?.keyboardUITestInputSessionRebuildCount ?? 0)
        let layoutBottomGap: CGFloat
        if let window = focusedTerminal.window {
            let terminalFrame = focusedTerminal.convert(focusedTerminal.bounds, to: window)
            layoutBottomGap = max(0, window.bounds.maxY - terminalFrame.maxY)
        } else {
            layoutBottomGap = -1
        }
        diagnostics = focusedTerminal.keyboardUITestDiagnostics(
            keyboardVisible: keyboardVisible,
            keyboardHeight: keyboardHeight
        ) + " focusedPane=\(focusedPaneId == Self.firstPaneId ? "first" : "second")"
            + " totalInputReloads=\(totalReloads)"
            + " totalInputRebuilds=\(totalRebuilds)"
            + " coordinatorKeyboardVisible=\(keyboardCoordinator.isSoftwareKeyboardVisible)"
            + " layoutBottomGap=\(layoutBottomGap)"
            + " paneShortcutActions=\(paneShortcutActionCount)"
            + " lastPaneShortcutAction=\(lastPaneShortcutAction)"
    }
}

struct TerminalKeyboardHarnessRepresentable: UIViewRepresentable {
    @EnvironmentObject private var ghosttyApp: GhosttyRuntime
    let tabManager: TerminalTabManager
    @Binding var terminalView: GhosttyTerminalView?
    @Binding var terminalReady: Bool
    let focusRequestID: Int
    let paneId: UUID
    var surfaceIdentifier = "vvterm.keyboardTest.terminalSurface"
    var surfaceLabel = "Terminal Keyboard Test Surface"
    let onInput: (Data) -> Void
    let onZoomAction: (TerminalZoomAction) -> Void
    let onPaneKeyboardShortcut: (TerminalSplitCommand) -> Void
    let onPaneFocus: () -> Void

    func makeUIView(context: Context) -> TerminalKeyboardHarnessContainerView {
        TerminalKeyboardHarnessContainerView()
    }

    func updateUIView(_ uiView: TerminalKeyboardHarnessContainerView, context: Context) {
        uiView.tabManager = tabManager
        uiView.paneId = paneId
        uiView.onInput = onInput
        uiView.onZoomAction = onZoomAction
        uiView.onPaneKeyboardShortcut = onPaneKeyboardShortcut
        uiView.onPaneFocus = onPaneFocus
        uiView.surfaceIdentifier = surfaceIdentifier
        uiView.surfaceLabel = surfaceLabel
        uiView.installTerminalIfNeeded(app: ghosttyApp.app, appWrapper: ghosttyApp)
        uiView.requestKeyboardFocusIfNeeded(focusRequestID: focusRequestID)

        if let installedTerminal = uiView.terminalView, terminalView !== installedTerminal {
            DispatchQueue.main.async {
                terminalView = installedTerminal
                terminalReady = true
            }
        }
    }

    static func dismantleUIView(_ uiView: TerminalKeyboardHarnessContainerView, coordinator: ()) {
        uiView.releaseTerminalInput()
        guard let terminal = uiView.terminalView,
              let tabManager = uiView.tabManager,
              let paneId = uiView.paneId else { return }
        Task { @MainActor in
            tabManager.unregisterTerminalSurface(terminal, for: paneId)
        }
    }
}

final class TerminalKeyboardHarnessContainerView: UIView {
    private(set) weak var terminalView: GhosttyTerminalView?
    // This retained sibling must track every terminal layout change so XCUITest
    // gets exact terminal geometry without becoming the UIKit hit-test owner.
    private let gestureSurface: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "vvterm.keyboardTest.gestureSurface"
        view.accessibilityLabel = "Terminal Gesture Test Surface"
        return view
    }()
    weak var tabManager: TerminalTabManager?
    var paneId: UUID?
    var onInput: ((Data) -> Void)?
    var onZoomAction: ((TerminalZoomAction) -> Void)?
    var onPaneKeyboardShortcut: ((TerminalSplitCommand) -> Void)?
    var onPaneFocus: (() -> Void)?
    var surfaceIdentifier = "vvterm.keyboardTest.terminalSurface"
    var surfaceLabel = "Terminal Keyboard Test Surface"
    private var lastHandledFocusRequestID: Int?
    private var pendingFocusRequestID = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        accessibilityIdentifier = "vvterm.keyboardTest.containerView"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installTerminalIfNeeded(app: ghostty_app_t?, appWrapper: GhosttyRuntime) {
        guard terminalView == nil, let app else { return }

        let initialSize = bounds.size == .zero ? CGSize(width: 390, height: 844) : bounds.size
        let terminal = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: appWrapper,
            paneId: "keyboard-ui-test",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "keyboard-ui-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        terminal.isAccessibilityElement = false
        terminal.imeProxyTextView.accessibilityIdentifier = surfaceIdentifier
        terminal.imeProxyTextView.accessibilityLabel = surfaceLabel
        terminal.imeProxyTextView.isAccessibilityElement = true
        terminal.acceptsTerminalInput = true
        terminal.keyboardUITestSetHardwareKeyboardAttached(false)
        terminal.writeCallback = { [weak self] data in
            DispatchQueue.main.async {
                self?.onInput?(data)
            }
        }
        terminal.setupWriteCallback()
        terminal.onZoomAction = { [weak self, weak terminal] action in
            guard let terminal else { return nil }
            self?.onZoomAction?(action)
            let overrides = terminal.surfacePresentationOverrides
            return TerminalZoomResult(
                presentationOverrides: overrides,
                effectiveFontSize: overrides.resolvedFontSize()
            )
        }
        terminal.onPaneKeyboardShortcut = { [weak self] action in
            self?.onPaneKeyboardShortcut?(action)
        }
        terminal.terminalContextMenuActions = TerminalContextMenuActions(
            focus: { [weak self] in self?.onPaneFocus?() },
            splitRight: {},
            splitLeft: {},
            splitDown: {},
            splitUp: {},
            currentTitle: { "" },
            setTitle: { _ in }
        )
        terminal.onReady = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            terminal.acceptsTerminalInput = true
            DispatchQueue.main.async {
                self.requestKeyboardFocusIfNeeded()
            }
        }

        addSubview(terminal)
        addSubview(gestureSurface)
        terminalView = terminal
        setNeedsLayout()

        DispatchQueue.main.async { [weak self] in
            self?.requestKeyboardFocusIfNeeded()
        }
    }

    func requestKeyboardFocusIfNeeded(focusRequestID: Int) {
        pendingFocusRequestID = focusRequestID
        requestKeyboardFocusIfNeeded()
    }

    func requestKeyboardFocusIfNeeded() {
        guard window != nil, let terminalView else { return }
        guard lastHandledFocusRequestID != pendingFocusRequestID else { return }
        lastHandledFocusRequestID = pendingFocusRequestID
        terminalView.acceptsTerminalInput = true
        _ = terminalView.requestKeyboardFocus(for: .initialActivation)
    }

    func releaseTerminalInput() {
        terminalView?.releaseTerminalInput()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.requestKeyboardFocusIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let terminalView else { return }
        terminalView.frame = bounds
        gestureSurface.frame = terminalView.frame
        if bounds.width > 0, bounds.height > 0 {
            terminalView.sizeDidChange(bounds.size)
        }
    }
}
#endif
