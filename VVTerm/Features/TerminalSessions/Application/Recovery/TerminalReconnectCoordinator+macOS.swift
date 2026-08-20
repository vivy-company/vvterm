#if os(macOS)
import Foundation

extension TerminalReconnectCoordinator {
    func receiveMacRecoverySignal(_ signal: MacTerminalRecoveryGate.Signal) {
        if case .applicationActivated = signal {
            receiveApplicationActivity(true)
        }
        if case .sleep = signal {
            pauseMacReconciliation()
        }

        let action = macRecoveryGate.receive(
            signal,
            networkReadiness: currentNetworkReadiness
        )
        switch action {
        case .none:
            return

        case .waitForNetwork(let generation):
            pauseMacReconciliation()
            markNetworkUnavailable(for: generation)
            for paneId in offlineMacRecoveryPaneIDs {
                _ = requestWaitingForNetwork(
                    for: paneId,
                    generation: generation,
                    replacingCurrent: true
                )
            }

        case .recover(let generation):
            markNetworkReady(for: generation)
            startMacReconciliationIfEligible()
        }
    }

    func pauseMacReconciliation() {
        macRecoveryTask?.cancel()
        macRecoveryTask = nil
        macReconciliationID = nil
    }

    func startMacReconciliationIfEligible() {
        guard applicationIsActive,
              !appIsLocked,
              currentNetworkReadiness == .ready,
              macRecoveryTask == nil,
              let generation = macRecoveryGate.recoveringGeneration else {
            return
        }
        let reconciliationID = UUID()
        macReconciliationID = reconciliationID
        let candidates = access.macRecoveryCandidates()
        let beginProbe = access.beginEternalTerminalProbe
        let verifyTransport = access.hasVerifiedLiveTransport
        let markMoshConnected = access.markMoshConnected
        macRecoveryTask = Task { [weak self] in
            var eternalTerminalProbeIDs: [UUID: UUID] = [:]
            for candidate in candidates
            where candidate.strategy == .allowEternalTerminalSelfRecovery {
                if let probeID = await beginProbe(candidate.paneId) {
                    eternalTerminalProbeIDs[candidate.paneId] = probeID
                }
                guard self?.isCurrentMacRecovery(
                    generation: generation,
                    reconciliationID: reconciliationID
                ) == true else { return }
            }
            if !eternalTerminalProbeIDs.isEmpty {
                try? await Task.sleep(for: .seconds(5))
            }

            for candidate in candidates {
                let paneId = candidate.paneId
                guard self?.isCurrentMacRecovery(
                    generation: generation,
                    reconciliationID: reconciliationID
                ) == true else { return }
                guard self?.recoveryPaneFacts(for: paneId) != nil else { continue }

                let transportIsLive = await verifyTransport(
                    paneId,
                    eternalTerminalProbeIDs[paneId]
                )
                guard self?.isCurrentMacRecovery(
                    generation: generation,
                    reconciliationID: reconciliationID
                ) == true else { return }

                if transportIsLive {
                    markMoshConnected(paneId)
                    continue
                }

                _ = self?.request(
                    for: paneId,
                    requiresReadyNetwork: true,
                    generation: generation,
                    replacingCurrent: true
                )
            }
            self?.finishMacRecovery(
                generation: generation,
                reconciliationID: reconciliationID
            )
        }
    }

    private func finishMacRecovery(
        generation: UUID,
        reconciliationID: UUID
    ) {
        guard isCurrentMacRecovery(
            generation: generation,
            reconciliationID: reconciliationID
        ) else { return }
        macRecoveryGate.complete(generation)
        macReconciliationID = nil
        macRecoveryTask = nil
    }

    private func isCurrentMacRecovery(
        generation: UUID,
        reconciliationID: UUID
    ) -> Bool {
        macRecoveryGate.recoveringGeneration == generation
            && macReconciliationID == reconciliationID
            && currentNetworkReadiness == .ready
            && applicationIsActive
            && !appIsLocked
            && !Task.isCancelled
    }
}
#endif
