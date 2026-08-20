#if os(iOS)
import Foundation

extension TerminalReconnectCoordinator {
    func handleIOSNetworkReadinessChange(_ readiness: TerminalNetworkReadiness) {
        switch readiness {
        case .unknown:
            return

        case .unavailable:
            let activeReconnectPaneIDs = activePaneIDs
            let candidatePaneIDs = recoveryPaneIDs.compactMap { paneId -> UUID? in
                guard let facts = recoveryPaneFacts(for: paneId),
                      facts.hasEstablishedConnection,
                      facts.connectionState.isConnecting
                        || activeReconnectPaneIDs.contains(paneId) else {
                    return nil
                }
                return paneId
            }
            for paneId in candidatePaneIDs {
                _ = queueIOSReconnectUntilNetworkReady(for: paneId)
            }

        case .ready:
            guard case .resume(let generation) = iosNetworkRecoveryGate.receive(
                .ready,
                shouldWait: false
            ) else { return }
            markNetworkReady(for: generation)
        }
    }

    @discardableResult
    func queueIOSReconnectUntilNetworkReady(
        for paneId: UUID,
        replacingCurrent: Bool = true
    ) -> Bool {
        guard recoveryPaneFacts(for: paneId) != nil,
              case .wait(let generation) = iosNetworkRecoveryGate.receive(
                .unavailable,
                shouldWait: true
              ) else { return false }
        return requestWaitingForNetwork(
            for: paneId,
            generation: generation,
            replacingCurrent: replacingCurrent
        )
    }
}
#endif
