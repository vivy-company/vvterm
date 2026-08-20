import SwiftUI

extension RemoteFileBrowserScreen {
    func securityApprovalPresentation<Content: View>(_ content: Content) -> some View {
        content
            .sshHostKeyTrustAlert(
                request: effectiveSecurityApprovalRequest,
                isPresented: hostKeyApprovalBinding,
                onCancel: { _ in cancelSecurityApproval() },
                onApprove: { _ in approveHostKeyAndRetry() }
            )
    }

    func remoteOperationErrorMessage(for error: Error) -> String {
        RemoteFileBrowserError.map(error).errorDescription ?? error.localizedDescription
    }

    @MainActor
    func presentOperationError(
        _ error: Error,
        retry: (@MainActor () -> Void)? = nil,
        onCancellation: (@MainActor () -> Void)? = nil
    ) {
        if presentSecurityApproval(
            for: error,
            retry: retry,
            onCancellation: onCancellation
        ) {
            return
        }
        presentation = .operationError(remoteOperationErrorMessage(for: error))
    }

    var hostKeyApprovalChallenge: KnownHostsManager.Challenge? {
        guard case .hostKey(let challenge) = effectiveSecurityApprovalRequest else {
            return nil
        }
        return challenge
    }

    var effectiveSecurityApprovalRequest: ServerSecurityApprovalRequest? {
        operationCoordinator.securityApprovalRequest
    }

    var hostKeyApprovalBinding: Binding<Bool> {
        Binding(get: { hostKeyApprovalChallenge != nil }, set: { _ in })
    }

    @discardableResult
    @MainActor
    func presentSecurityApproval(
        for error: Error,
        retry: (@MainActor () -> Void)?,
        onCancellation: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard effectiveSecurityApprovalRequest == nil else { return false }
        guard operationCoordinator.requestSecurityApproval(
            for: error,
            retry: retry ?? {},
            onCancellation: onCancellation ?? {}
        ) else {
            if case .hostKeyApprovalRequired = RemoteFileBrowserError.map(error) {
                presentation = .operationError(ServerSecurityApprovalError.unavailable.localizedDescription)
                return true
            }
            return false
        }
        return true
    }

    @MainActor
    func presentDirectorySecurityApprovalIfNeeded() {
        guard let error = browser.error(for: fileTab) else { return }
        _ = presentSecurityApproval(for: error, retry: {
            Task {
                await browser.refresh(server: server, tab: fileTab)
            }
        })
    }

    @MainActor
    func presentViewerSecurityApprovalIfNeeded() {
        guard let error = browser.viewerError(for: fileTab),
              let entry = snapshot.selectedEntry else { return }
        _ = presentSecurityApproval(for: error, retry: {
            Task {
                await browser.loadPreview(for: entry, in: fileTab, server: server)
            }
        })
    }

    @MainActor
    func cancelSecurityApproval() {
        guard effectiveSecurityApprovalRequest != nil else { return }
        if let error = operationCoordinator.cancelSecurityRequest() {
            presentation = .operationError(error.localizedDescription)
        }
    }

    @MainActor
    func approveHostKeyAndRetry() {
        guard effectiveSecurityApprovalRequest != nil else { return }
        if let error = operationCoordinator.approveSecurityRequest() {
            presentation = .operationError(error.localizedDescription)
        }
    }
}
