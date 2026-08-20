//
//  GhosttyTerminalClipboardConfirmation+macOS.swift
//  VVTerm
//
//  macOS clipboard confirmation presentation.
//

#if os(macOS)
import AppKit

extension GhosttyTerminalView {
    func handleClipboardWrite(_ text: String, action: TerminalClipboardWriteAction) {
        switch action {
        case .writeImmediately:
            Clipboard.copy(text)
        case .requestConfirmation:
            clipboardConfirmationQueue.enqueue(kind: .remoteWrite) { decision in
                guard decision == .allow else { return }
                Clipboard.copy(text)
            }
            presentNextClipboardConfirmationIfPossible()
        }
    }

    func handleClipboardConfirmation(
        _ text: String,
        state: UnsafeMutableRawPointer,
        kind: TerminalClipboardConfirmationKind
    ) {
        guard let surface = surface?.unsafeCValue else { return }
        clipboardConfirmationQueue.enqueue(kind: kind) { decision in
            let completedValue = decision == .allow ? text : ""
            completedValue.withCString { pointer in
                ghostty_surface_complete_clipboard_request(surface, pointer, state, true)
            }
        }
        presentNextClipboardConfirmationIfPossible()
    }

    private func presentNextClipboardConfirmationIfPossible() {
        guard !isShuttingDown,
              presentedClipboardConfirmation == nil,
              let request = clipboardConfirmationQueue.requestToPresent else {
            return
        }
        guard let window, window.attachedSheet == nil else {
            scheduleClipboardConfirmationRetry(for: request.id)
            return
        }

        let alert = NSAlert()
        alert.messageText = request.kind.title
        alert.informativeText = request.kind.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        presentedClipboardConfirmation = alert

        alert.beginSheetModal(for: window) { [weak self] response in
            let decision: TerminalClipboardConfirmationDecision = response == .alertFirstButtonReturn
                ? .allow
                : .cancel
            self?.finishClipboardConfirmation(id: request.id, decision: decision)
        }
    }

    private func finishClipboardConfirmation(
        id: UUID,
        decision: TerminalClipboardConfirmationDecision
    ) {
        presentedClipboardConfirmation = nil
        clipboardConfirmationRetryCount = 0
        _ = clipboardConfirmationQueue.resolve(id: id, decision: decision)
        scheduleClipboardConfirmationRetry(for: clipboardConfirmationQueue.requestToPresent?.id)
    }

    private func scheduleClipboardConfirmationRetry(for requestID: UUID?) {
        guard let requestID else { return }
        clipboardConfirmationRetryWorkItem?.cancel()

        switch TerminalClipboardPresentationRetryPolicy.action(
            after: clipboardConfirmationRetryCount
        ) {
        case .cancel:
            clipboardConfirmationRetryCount = 0
            _ = clipboardConfirmationQueue.resolve(id: requestID, decision: .cancel)
            scheduleClipboardConfirmationRetry(for: clipboardConfirmationQueue.requestToPresent?.id)
            return
        case .retry(let nextAttempt):
            clipboardConfirmationRetryCount = nextAttempt
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.clipboardConfirmationRetryWorkItem = nil
            self?.presentNextClipboardConfirmationIfPossible()
        }
        clipboardConfirmationRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func cancelClipboardConfirmations() {
        clipboardConfirmationRetryWorkItem?.cancel()
        clipboardConfirmationRetryWorkItem = nil
        clipboardConfirmationRetryCount = 0
        clipboardConfirmationQueue.cancelAll()
        if let alert = presentedClipboardConfirmation,
           let sheetParent = alert.window.sheetParent {
            sheetParent.endSheet(alert.window, returnCode: .abort)
        }
        presentedClipboardConfirmation = nil
    }
}

#endif
