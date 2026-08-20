//
//  GhosttyTerminalKeyboardDiagnostics+iOS.swift
//  VVTerm
//
//  iOS terminal keyboard diagnostics and lifecycle logging.
//

#if os(iOS)
import UIKit
import os

extension GhosttyTerminalView {
    private static let keyboardLifecycleLoggingEnabled = DebugLogConfiguration.isEnabled("keyboard")
    private static let keyboardLifecycleLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "TerminalKeyboardInput"
    )

    func keyboardCoordinatorDiagnosticSnapshot() -> TerminalKeyboardCoordinatorDiagnosticSnapshot {
        let keyboardLayoutFrame: CGRect?
        let screenFrame: CGRect?
        if let window {
            let frameInWindow = convert(keyboardLayoutGuide.layoutFrame, to: window)
            keyboardLayoutFrame = window.convert(
                frameInWindow,
                to: window.screen.coordinateSpace
            )
            screenFrame = window.screen.bounds
        } else {
            keyboardLayoutFrame = nil
            screenFrame = nil
        }
        return TerminalKeyboardCoordinatorDiagnosticSnapshot(
            windowAttached: window != nil,
            windowIsKey: window?.isKeyWindow == true,
            sceneActivationState: window?.windowScene.map { String(describing: $0.activationState) } ?? "nil",
            isFirstResponder: isFirstResponder,
            isSoftwareInputActive: isKeyboardTextInputActive,
            keyboardLayoutFrame: keyboardLayoutFrame,
            screenFrame: screenFrame,
            screenIdentifier: window.map { ObjectIdentifier($0.screen) },
            isSoftwareKeyboardSuppressed: shouldSuppressSoftwareKeyboard,
            isKeyboardInBrowseMode: isKeyboardInBrowseMode
        )
    }

    private func keyboardLifecycleDescription() -> String {
        let snapshot = keyboardCoordinatorDiagnosticSnapshot()
        return [
            "terminal=\(ObjectIdentifier(self))",
            "inputResponder=\(ObjectIdentifier(imeProxyTextView))",
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil")",
            snapshot.lifecycleDescription,
            "viewFirstResponder=\(super.isFirstResponder)",
            "canBecome=\(imeProxyTextView.canBecomeFirstResponder)",
            "canResign=\(imeProxyTextView.canResignFirstResponder)",
            "hardware=\(hasHardwareKeyboardAttached)",
            "forced=\(keyboardFocusPolicy.forcesSoftwareKeyboardPresentation)",
            "browse=\(keyboardFocusPolicy.isBrowsing)",
            "softwareSuppressed=\(shouldSuppressSoftwareKeyboard)",
            "accessorySuppressed=\(suppressAccessoryForMissingSoftwareKeyboard)",
            "accessoryAttached=\(keyboardToolbar?.window != nil)",
            "inputView=\(shouldSuppressSoftwareKeyboard ? "policyHidden" : "system")",
            "language=\(imeProxyTextView.textInputMode?.primaryLanguage ?? "nil")",
            "layoutFrame=\(keyboardLayoutGuide.layoutFrame.debugDescription)",
            "bounds=\(bounds.debugDescription)",
            "safeArea=\(safeAreaInsets)",
            "grid=\(lastReportedGrid.cols)x\(lastReportedGrid.rows)",
        ].joined(separator: " ")
    }

    func logKeyboardLifecycle(
        _ event: String,
        result: Bool? = nil,
        detail: String = ""
    ) {
        guard Self.keyboardLifecycleLoggingEnabled else { return }
        let resultDescription = result.map(String.init) ?? "none"
        Self.keyboardLifecycleLogger.info(
            "event=\(event, privacy: .public) result=\(resultDescription, privacy: .public) detail=\(detail, privacy: .public) \(self.keyboardLifecycleDescription(), privacy: .public)"
        )
    }
}

#endif
