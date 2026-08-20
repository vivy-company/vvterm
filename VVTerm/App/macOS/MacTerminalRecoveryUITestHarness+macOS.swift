#if os(macOS) && DEBUG
import Combine
import SwiftUI

@MainActor
final class MacTerminalRecoveryUITestHarnessModel: ObservableObject {
    enum Outcome: Equatable {
        case idle
        case waitingForNetwork
        case reconnecting
        case connected
        case failed
    }

    @Published private(set) var outcome: Outcome = .idle
    var simulatedInterval: TimeInterval { Self.simulatedSleepInterval }
    private(set) var cleanupCount = 0
    private(set) var replacementCount = 0
    private(set) var observedOutcomes: Set<Outcome> = [.idle]
    private(set) var lastAttemptStartedAt: Date?

    nonisolated private static let simulatedSleepInterval: TimeInterval = 8 * 60 * 60
    nonisolated private static func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
    private let paneId = UUID()
    private let simulatesSuccess: Bool
    private let cleanupBlocker = MacTerminalRecoveryHarnessBlocker()
    private var coordinatorStorage: TerminalReconnectCoordinator?

    private var coordinator: TerminalReconnectCoordinator {
        if let coordinatorStorage {
            return coordinatorStorage
        }
        let coordinator = makeCoordinator()
        coordinatorStorage = coordinator
        return coordinator
    }

    private func makeCoordinator() -> TerminalReconnectCoordinator {
        TerminalReconnectCoordinator(
            access: TerminalReconnectAccess(
            paneFacts: { [weak self] paneId in
                guard let self, paneId == self.paneId else { return nil }
                return TerminalReconnectPaneFacts(
                    connectionState: self.connectionState,
                    hasEstablishedConnection: true
                )
            },
            paneIDs: { [weak self] in self.map { [$0.paneId] } ?? [] },
            paneIDsForServer: { _ in [] },
            networkPathBecameReady: { _ in },
            prepareTransport: { [weak self] _ in
                self?.cleanupCount += 1
                let blocker = self?.cleanupBlocker
                await blocker?.wait()
            },
            startConnection: { [weak self] _ in
                guard let self else { return false }
                replacementCount += 1
                let replacement = replacementCount
                setOutcome(.reconnecting)
                guard simulatesSuccess else { return true }
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(2))
                    await self?.completeSimulatedConnection(replacement: replacement)
                }
                return true
            },
            failConnection: { [weak self] _ in
                self?.setOutcome(.failed)
                if let blocker = self?.cleanupBlocker {
                    Task { await blocker.release() }
                }
            },
            offlineMacRecoveryPaneIDs: { [weak self] in self.map { [$0.paneId] } ?? [] },
            macRecoveryCandidates: { [] },
            beginEternalTerminalProbe: { _ in nil },
            hasVerifiedLiveTransport: { _, _ in false },
            markMoshConnected: { _ in }
            ),
            initialNetworkReadiness: .unavailable,
            networkUpdates: nil,
            applicationIsActive: { true },
            initialAppIsLocked: false,
            appLockUpdates: nil,
            preparationTimeout: .milliseconds(20),
            connectionTimeout: .milliseconds(30),
            retryDelay: .seconds(5),
            now: { Date(timeIntervalSince1970: Self.simulatedSleepInterval) },
            sleep: Self.sleep,
            onEvent: { _ in },
            onChange: {}
        )
    }

    init(simulatesSuccess: Bool) {
        self.simulatesSuccess = simulatesSuccess
    }

    func run() {
        guard outcome == .idle || outcome == .failed else { return }
        setOutcome(.waitingForNetwork)

        coordinator.receiveMacRecoverySignal(.sleep)
        coordinator.receiveMacRecoverySignal(.wake)
        lastAttemptStartedAt = coordinator.attempt(for: paneId)?.startedAt
        coordinator.receiveNetworkReadiness(.ready)

        // Duplicate wake, activation, and ready notifications must not create
        // another replacement for this sleep generation.
        coordinator.receiveMacRecoverySignal(.wake)
        coordinator.receiveMacRecoverySignal(.applicationActivated)
        coordinator.receiveNetworkReadiness(.ready)
    }

    private var connectionState: ConnectionState {
        switch outcome {
        case .idle, .waitingForNetwork:
            .disconnected
        case .reconnecting:
            .reconnecting(attempt: 1)
        case .connected:
            .connected
        case .failed:
            .failed(.external(
                message: "Connection timed out",
                retryDisposition: .automatic,
                requiredAction: nil
            ))
        }
    }

    private func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
        observedOutcomes.insert(outcome)
    }

    private func completeSimulatedConnection(replacement: Int) async {
        guard replacementCount == replacement,
              coordinator.attempt(for: paneId)?.phase == .connecting else {
            return
        }
        setOutcome(.connected)
        coordinator.complete(for: paneId)
        await cleanupBlocker.release()
    }
}

private actor MacTerminalRecoveryHarnessBlocker {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.resume() }
    }
}

struct MacTerminalRecoveryUITestHarness: View {
    @StateObject private var model: MacTerminalRecoveryUITestHarnessModel

    init(simulatesSuccess: Bool) {
        _model = StateObject(
            wrappedValue: MacTerminalRecoveryUITestHarnessModel(
                simulatesSuccess: simulatesSuccess
            )
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            switch model.outcome {
            case .idle, .reconnecting:
                ProgressView("Reconnecting…")
            case .waitingForNetwork:
                ProgressView("Waiting for network…")
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
            case .failed:
                Text("Connection timed out. Please retry.")
                Button("Retry") { model.run() }
                    .accessibilityIdentifier("vvterm.macRecovery.retry")
            }

            Text("simulatedSleepHours=\(Int(model.simulatedInterval / 3_600))")
                .font(.caption.monospaced())
        }
        .frame(minWidth: 420, minHeight: 240)
        .accessibilityIdentifier("vvterm.macRecovery.\(String(describing: model.outcome))")
        .task { model.run() }
    }
}
#endif
