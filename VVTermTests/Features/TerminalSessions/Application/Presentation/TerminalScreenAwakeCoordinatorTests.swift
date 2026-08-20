#if os(iOS)
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalScreenAwakeCoordinatorTests {
    private final class IdleTimerSpy: TerminalIdleTimerControlling {
        private(set) var values: [Bool] = []

        func setIdleTimerDisabled(_ isDisabled: Bool) {
            values.append(isDisabled)
        }
    }

    @Test
    func requestRequiresEnabledVisibleForegroundTerminalRoute() {
        #expect(
            TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: true,
                terminalSelected: true,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: false,
                routeVisible: true,
                terminalSelected: true,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: false,
                terminalSelected: true,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: true,
                terminalSelected: false,
                sceneIsInBackground: false
            )
        )
        #expect(
            !TerminalScreenAwakeCoordinator.shouldRequest(
                preferenceEnabled: true,
                routeVisible: true,
                terminalSelected: true,
                sceneIsInBackground: true
            )
        )
    }

    @Test
    func activeRequestsAreAggregatedAcrossTerminalScenes() {
        let idleTimer = IdleTimerSpy()
        let coordinator = TerminalScreenAwakeCoordinator(idleTimer: idleTimer)
        let firstScene = UUID()
        let secondScene = UUID()

        coordinator.update(isRequested: true, for: firstScene)
        coordinator.update(isRequested: true, for: firstScene)
        coordinator.update(isRequested: true, for: secondScene)
        #expect(idleTimer.values == [true])

        coordinator.update(isRequested: false, for: firstScene)
        #expect(idleTimer.values == [true])

        coordinator.update(isRequested: true, for: secondScene)
        coordinator.update(isRequested: false, for: secondScene)
        coordinator.update(isRequested: false, for: secondScene)
        #expect(idleTimer.values == [true, false])
    }
}
#endif
