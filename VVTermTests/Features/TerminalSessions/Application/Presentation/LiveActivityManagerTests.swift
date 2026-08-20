import Foundation
import Testing
@testable import VVTerm

@MainActor
struct LiveActivityManagerTests {
    private final class ControllerSpy: TerminalLiveActivityControlling {
        private(set) var reconciledTargets: [TerminalLiveActivityTarget] = []
        private(set) var terminationCallCount = 0
        var terminationResult = true
        var shouldBlockFirstReconciliation = false

        private var firstReconciliationContinuation: CheckedContinuation<Void, Never>?

        func reconcile(toward target: TerminalLiveActivityTarget) async {
            reconciledTargets.append(target)
            guard shouldBlockFirstReconciliation, reconciledTargets.count == 1 else {
                return
            }
            await withCheckedContinuation { continuation in
                firstReconciliationContinuation = continuation
            }
        }

        func endForApplicationTermination() -> Bool {
            terminationCallCount += 1
            return terminationResult
        }

        func releaseFirstReconciliation() {
            firstReconciliationContinuation?.resume()
            firstReconciliationContinuation = nil
        }
    }

    @Test
    func refreshMapsConnectionStateToSemanticTargets() async {
        let controller = ControllerSpy()
        let manager = LiveActivityManager(controller: controller)

        manager.refresh(with: [.connected, .idle])
        await waitUntil { controller.reconciledTargets.count == 1 }
        manager.refresh(with: [.disconnected, .failed(terminalExternalFailure("offline"))])
        await waitUntil { controller.reconciledTargets.count == 2 }

        #expect(
            controller.reconciledTargets == [
                .active(TerminalLiveActivitySnapshot(status: .connected, activeCount: 1)),
                .end,
            ]
        )
    }

    @Test
    func refreshCoalescesPendingTargetsToTheLatestRequest() async {
        let controller = ControllerSpy()
        controller.shouldBlockFirstReconciliation = true
        let manager = LiveActivityManager(controller: controller)

        manager.refresh(with: [.connected])
        await waitUntil { controller.reconciledTargets.count == 1 }
        manager.refresh(with: [.connecting])
        manager.refresh(with: [.reconnecting(attempt: 2)])

        controller.releaseFirstReconciliation()
        await waitUntil { controller.reconciledTargets.count == 2 }

        #expect(
            controller.reconciledTargets == [
                .active(TerminalLiveActivitySnapshot(status: .connected, activeCount: 1)),
                .active(TerminalLiveActivitySnapshot(status: .reconnecting, activeCount: 1)),
            ]
        )
    }

    @Test
    func applicationTerminationDelegatesAndReturnsControllerResult() {
        let controller = ControllerSpy()
        controller.terminationResult = false
        let manager = LiveActivityManager(controller: controller)

        let completed = manager.endForApplicationTermination()

        #expect(!completed)
        #expect(controller.terminationCallCount == 1)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for Live Activity reconciliation", sourceLocation: sourceLocation)
    }
}
