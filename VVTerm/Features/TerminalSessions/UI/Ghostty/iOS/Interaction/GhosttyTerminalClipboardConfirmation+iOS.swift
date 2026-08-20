//
//  GhosttyTerminalClipboardConfirmation+iOS.swift
//  VVTerm
//
//  iOS clipboard confirmation presentation.
//

#if os(iOS)
import UIKit

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

        guard let presenter = nearestPresentingViewController(),
              !(presenter is UIAlertController),
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else {
            scheduleClipboardConfirmationRetry(for: request.id)
            return
        }

        let alert = UIAlertController(
            title: request.kind.title,
            message: request.kind.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.finishClipboardConfirmation(id: request.id, decision: .cancel)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Allow"), style: .default) { [weak self] _ in
            self?.finishClipboardConfirmation(id: request.id, decision: .allow)
        })
        presentedClipboardConfirmation = alert
        presenter.present(alert, animated: true)
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
        presentedClipboardConfirmation?.dismiss(animated: false)
        presentedClipboardConfirmation = nil
    }
}

#endif
