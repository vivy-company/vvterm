#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

struct AppSceneLifecyclePolicyTests {
    @Test
    @MainActor
    func foregroundRefreshesNetworkBeforeResumingTerminals() {
        let delegate = AppDelegate()
        var events: [String] = []

        delegate.handleSceneDidBecomeActive(
            refreshNetwork: { events.append("network") },
            resume: { events.append("terminals") }
        )

        #expect(events == ["network", "terminals"])
    }

    @Test
    func fullyBackgroundedScenesHandleBackgroundTransition() {
        #expect(AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: [.background, .unattached]
        ))
    }

    @Test
    func activeSceneKeepsTerminalsConnected() {
        #expect(!AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: [.background, .foregroundActive]
        ))
    }

    @Test
    func inactiveSceneKeepsTerminalsConnectedForSystemOverlays() {
        #expect(!AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: [.foregroundInactive]
        ))
    }

    @Test
    @MainActor
    func lastBackgroundedSceneLocksWithoutDisconnectingTerminals() {
        let delegate = AppDelegate()
        var actions: [String] = []

        delegate.handleSceneDidEnterBackground(
            connectedSceneStates: [.background, .unattached],
            lock: { actions.append("lock") }
        )

        #expect(actions == ["lock"])
    }

    @Test
    @MainActor
    func anotherForegroundScenePreventsGlobalBackgroundHandling() {
        let delegate = AppDelegate()
        var actions: [String] = []

        delegate.handleSceneDidEnterBackground(
            connectedSceneStates: [.background, .foregroundInactive],
            lock: { actions.append("lock") }
        )

        #expect(actions.isEmpty)
    }

    @Test
    @MainActor
    func lastDeactivatingScenePreparesResumableTransportsBeforeBackground() {
        let delegate = AppDelegate()
        var actions: [String] = []

        delegate.handleSceneWillDeactivate(
            connectedOtherSceneStates: [],
            prepare: { actions.append("prepare") }
        )

        #expect(actions == ["prepare"])
    }

    @Test
    @MainActor
    func anotherForegroundScenePreventsGlobalResumableTransportPreparation() {
        let delegate = AppDelegate()
        var actions: [String] = []

        delegate.handleSceneWillDeactivate(
            connectedOtherSceneStates: [.foregroundActive],
            prepare: { actions.append("prepare") }
        )

        #expect(actions.isEmpty)
    }

    @Test
    func pausedTerminalResumesFromCurrentSceneFactsWithoutPhaseEdge() {
        #expect(TerminalRenderingPolicy.transition(
            terminalIsActive: true,
            sceneIsActive: true,
            renderingIsPaused: true
        ) == .resume)
    }

    @Test
    func backgroundTerminalPausesFromCurrentSceneFacts() {
        #expect(TerminalRenderingPolicy.transition(
            terminalIsActive: true,
            sceneIsActive: false,
            renderingIsPaused: false
        ) == .pause)
    }

    @Test
    func renderingAlreadyMatchesSceneNeedsNoTransition() {
        #expect(TerminalRenderingPolicy.transition(
            terminalIsActive: true,
            sceneIsActive: true,
            renderingIsPaused: false
        ) == .none)
    }

    @Test
    func pausedRenderingPreservesTerminalGridAcrossTransientLayoutChanges() {
        #expect(TerminalSurfaceGeometryPolicy.update(
            renderingIsPaused: true,
            preservesForegroundKeyboardGrid: false,
            currentSize: CGSize(width: 390, height: 420),
            proposedSize: CGSize(width: 390, height: 780)
        ) == .preserveCurrentGrid)
        #expect(TerminalSurfaceGeometryPolicy.update(
            renderingIsPaused: false,
            preservesForegroundKeyboardGrid: true,
            currentSize: CGSize(width: 390, height: 420),
            proposedSize: CGSize(width: 390, height: 780)
        ) == .preserveCurrentGrid)
        #expect(TerminalSurfaceGeometryPolicy.update(
            renderingIsPaused: false,
            preservesForegroundKeyboardGrid: true,
            currentSize: CGSize(width: 390, height: 420),
            proposedSize: CGSize(width: 390, height: 420)
        ) == .apply)
    }
}
#endif
