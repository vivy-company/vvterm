import Foundation

nonisolated enum TerminalLiveActivityTarget: Equatable, Sendable {
    case end
    case active(TerminalLiveActivitySnapshot)
}

@MainActor
protocol TerminalLiveActivityControlling: AnyObject {
    func reconcile(toward target: TerminalLiveActivityTarget) async
    func endForApplicationTermination() -> Bool
}

@MainActor
final class LiveActivityManager {
    private let controller: any TerminalLiveActivityControlling
    private var requestedTarget: TerminalLiveActivityTarget?
    private var reconciliationTask: Task<Void, Never>?

    init(controller: any TerminalLiveActivityControlling) {
        self.controller = controller
    }

    func refresh(with connectionStates: [ConnectionState]) {
        requestedTarget = TerminalLiveActivityPolicy.snapshot(for: connectionStates)
            .map(TerminalLiveActivityTarget.active) ?? .end
        guard reconciliationTask == nil else { return }

        reconciliationTask = Task { [weak self] in
            await self?.reconcileRequestedTargets()
        }
    }

    @discardableResult
    func endForApplicationTermination() -> Bool {
        requestedTarget = .end
        return controller.endForApplicationTermination()
    }

    private func reconcileRequestedTargets() async {
        while let target = requestedTarget {
            requestedTarget = nil
            await controller.reconcile(toward: target)
        }
        reconciliationTask = nil
    }
}
