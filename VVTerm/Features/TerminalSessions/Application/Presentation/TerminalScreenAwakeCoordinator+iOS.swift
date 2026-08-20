#if os(iOS)
import Combine
import Foundation

@MainActor
protocol TerminalIdleTimerControlling: AnyObject {
    func setIdleTimerDisabled(_ isDisabled: Bool)
}

/// Aggregates visible terminal routes because the iOS idle timer is shared by
/// every VVTerm window in the process.
@MainActor
final class TerminalScreenAwakeCoordinator: ObservableObject {
    private var requestingRouteIDs: Set<UUID> = []
    private let idleTimer: any TerminalIdleTimerControlling

    init(idleTimer: any TerminalIdleTimerControlling) {
        self.idleTimer = idleTimer
    }

    nonisolated static func shouldRequest(
        preferenceEnabled: Bool,
        routeVisible: Bool,
        terminalSelected: Bool,
        sceneIsInBackground: Bool
    ) -> Bool {
        preferenceEnabled
            && routeVisible
            && terminalSelected
            && !sceneIsInBackground
    }

    func update(isRequested: Bool, for routeID: UUID) {
        let wasIdleTimerDisabled = !requestingRouteIDs.isEmpty

        if isRequested {
            requestingRouteIDs.insert(routeID)
        } else {
            requestingRouteIDs.remove(routeID)
        }

        let shouldDisableIdleTimer = !requestingRouteIDs.isEmpty
        guard shouldDisableIdleTimer != wasIdleTimerDisabled else { return }
        idleTimer.setIdleTimerDisabled(shouldDisableIdleTimer)
    }
}
#endif
