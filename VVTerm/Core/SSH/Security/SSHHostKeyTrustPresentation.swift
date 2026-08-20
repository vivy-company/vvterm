import Foundation

nonisolated struct SSHHostKeyTrustPresentation {
    let title: String
    let message: String
    let approvalButtonTitle: String
    let isDestructive: Bool

    init(request: ServerSecurityApprovalRequest) {
        switch request {
        case .hostKey(let challenge):
            self.init(challenge: challenge)
        }
    }

    init(challenge: KnownHostsManager.Challenge) {
        let endpoint = "\(challenge.host):\(challenge.port)"
        let presented = String(
            format: String(localized: "Host: %@\nKey type: %@\nFingerprint: %@"),
            endpoint,
            challenge.keyTypeName,
            challenge.fingerprint
        )

        switch challenge.kind {
        case .firstUse:
            title = String(localized: "Trust SSH Host?")
            message = String(
                format: String(localized: "VVTerm has not seen this SSH host before. Verify this fingerprint through a trusted source before you continue.\n\n%@"),
                presented
            )
            approvalButtonTitle = String(localized: "Trust and Reconnect")
            isDestructive = false
        case .changed(let previousFingerprint):
            title = String(localized: "Replace Trusted Host?")
            message = String(
                format: String(localized: "The SSH host key changed. Only continue if you recreated this server or verified the new key.\n\nPrevious: %@\n%@"),
                previousFingerprint,
                presented
            )
            approvalButtonTitle = String(localized: "Replace and Reconnect")
            isDestructive = true
        }
    }
}
