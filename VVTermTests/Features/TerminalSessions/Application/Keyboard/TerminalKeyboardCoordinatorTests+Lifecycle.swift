#if os(iOS)
import Combine
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct Lifecycle {
        @Test
        @MainActor
        func reconnectWithTypingIntentKeepsOneInputSessionOwner() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            session.resetCommands()
    
            coordinator.setPaneInputEligible(
                TerminalKeyboardCoordinator.paneInputEligible(
                    connectionState: .reconnecting(attempt: 1),
                    shouldRestoreOnReconnect: true
                ),
                for: paneId
            )
            await drainMainQueue()
    
            #expect(session.releaseCount == 0)
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 0)
    
            coordinator.setPaneInputEligible(
                TerminalKeyboardCoordinator.paneInputEligible(
                    connectionState: .connected,
                    shouldRestoreOnReconnect: true
                ),
                for: paneId
            )
            await drainMainQueue()
    
            #expect(session.releaseCount == 0)
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 0)
        }
    
        @Test
        @MainActor
        func onlyActiveTerminalSceneActivationRequestsDeferredPresentationRepair() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
            session.resetCommands()
    
            coordinator.activeTerminalSceneDidActivate(for: UUID())
            await drainMainQueue()
    
            #expect(session.rebuildCount == 0)
            #expect(session.acquireCount == 0)
            #expect(session.accessoryAppearanceRefreshCount == 0)
    
            coordinator.activeTerminalSceneDidActivate(for: paneId)
            await drainMainQueue()
    
            #expect(session.rebuildCount == 0)
            #expect(session.acquireCount == 0)
            #expect(session.accessoryAppearanceRefreshCount == 1)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
    
            await waitForMainActorCondition { [coordinator] in
                session.rebuildCount == 1
            }
    
            #expect(session.rebuildCount == 1)
            #expect(session.acquireCount == 1)
        }
    
        @Test
        @MainActor
        func appSwitchPreservesResponderAndTypingIntent() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            session.resetCommands()
    
            coordinator.activeTerminalSceneWillDeactivate(for: paneId)
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
            await drainMainQueue()

            #expect(session.accessorySuppressionRequests.isEmpty)
            #expect(session.releaseCount == 0)
            #expect(session.rebuildCount == 0)
            #expect(session.snapshot.isSoftwareInputActive)

            coordinator.activeTerminalSceneDidActivate(for: paneId)
            await drainMainQueue()

            #expect(session.releaseCount == 0)
            #expect(session.rebuildCount == 0)
            #expect(session.acquireCount == 0)
            #expect(session.snapshot.isSoftwareInputActive)
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(session.releaseCount == 0)
            #expect(session.rebuildCount == 0)
            #expect(session.accessorySuppressionRequests.last == false)
        }
    
        @Test
        @MainActor
        func terminalRegistrationRecoversFloatingKeyboardFrameMissedDuringStartup() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let floating = CGRect(x: 930, y: 620, width: 320, height: 280)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.keyboardLayoutFrame = floating
            session.snapshot.screenFrame = screen
            let coordinator = TerminalKeyboardCoordinator()
    
            coordinator.setViewActive(true)
            coordinator.keyboardUITestReceiveKeyboardEndFrame(floating, isLocal: true)
            #expect(coordinator.softwareKeyboardPresentation == .hidden)
    
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
    
            #expect(
                coordinator.softwareKeyboardPresentation
                    == .floating(frame: floating)
            )
            #expect(session.accessorySuppressionRequests.last == false)
            #expect(session.accessoryReloadCount == 0)
            #expect(session.rebuildCount == 0)
        }
    
        @Test
        @MainActor
        func settledLocalKeyboardHideSuppressesOrphanAccessory() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_024, height: 1_000)
            let docked = CGRect(x: 0, y: 700, width: 1_024, height: 300)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = screen
            let eventSource = TerminalKeyboardCoordinatorEventSourceSpy()
            let coordinator = TerminalKeyboardCoordinator(
                keyboardEventSource: eventSource,
                lifecycleLoggingEnabled: false
            )
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            eventSource.send(.frameChanged(docked))
            session.snapshot.keyboardLayoutFrame = docked
            session.resetCommands()
    
            eventSource.send(.hidden)
    
            #expect(session.accessorySuppressionRequests.isEmpty)
            #expect(coordinator.softwareKeyboardPresentation == .hidden)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
    
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(session.accessorySuppressionRequests == [true])
            #expect(session.accessoryReloadCount == 1)
            #expect(session.rebuildCount == 0)
        }
    
        @Test
        @MainActor
        func keyboardReturnCancelsOrphanAccessorySuppression() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_024, height: 1_000)
            let docked = CGRect(x: 0, y: 700, width: 1_024, height: 300)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = screen
            let eventSource = TerminalKeyboardCoordinatorEventSourceSpy()
            let coordinator = TerminalKeyboardCoordinator(
                keyboardEventSource: eventSource,
                lifecycleLoggingEnabled: false
            )
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            eventSource.send(.frameChanged(docked))
            session.snapshot.keyboardLayoutFrame = docked
            session.resetCommands()
    
            eventSource.send(.hidden)
            #expect(coordinator.softwareKeyboardPresentation == .hidden)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
            eventSource.send(.frameChanged(docked))
    
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(!session.accessorySuppressionRequests.isEmpty)
            #expect(session.accessorySuppressionRequests.allSatisfy { !$0 })
            #expect(session.accessoryReloadCount == 0)
            #expect(session.rebuildCount == 0)
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
        }
    
        @Test
        @MainActor
        func nonLocalKeyboardNotificationReleasesResponderWithoutReloadOrRebuild() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let docked = CGRect(x: 0, y: 650, width: 1_366, height: 374)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = screen
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            coordinator.keyboardUITestReceiveKeyboardEndFrame(docked, isLocal: true)
            session.resetCommands()
    
            coordinator.keyboardUITestReceiveKeyboardEndFrame(docked, isLocal: false)
            await drainMainQueue()
    
            #expect(coordinator.softwareKeyboardPresentation == .hidden)
            #expect(session.accessorySuppressionRequests.isEmpty)
            #expect(session.accessoryReloadCount == 0)
            #expect(session.releaseCount == 1)
            #expect(session.rebuildCount == 0)
            #expect(!session.snapshot.isSoftwareInputActive)
    
            await drainMainQueue()
            #expect(session.acquireCount == 0)
        }
    
        @Test
        @MainActor
        func staleReacquisitionCannotRestoreResponderAfterExternalOwnership() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.completesRebuildImmediately = false
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            session.resetCommands()
    
            coordinator.directTouchOnTerminal()
            await drainMainQueue()
            #expect(session.rebuildCount == 1)
            #expect(session.releaseCount == 1)
    
            coordinator.keyboardUITestReceiveKeyboardEndFrame(
                CGRect(x: 0, y: 650, width: 1_366, height: 374),
                isLocal: false
            )
            session.completeNextRebuild()
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(!session.snapshot.isSoftwareInputActive)
    
            coordinator.directTouchOnTerminal()
            await drainMainQueue()
    
            #expect(session.acquireCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func inactiveTerminalIgnoresSameScreenKeyboardFrameFromForegroundApp() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let docked = CGRect(x: 0, y: 650, width: 1_366, height: 374)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = screen
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            coordinator.keyboardUITestReceiveKeyboardEndFrame(docked, isLocal: true)
    
            coordinator.activeTerminalSceneWillDeactivate(for: paneId)
            session.resetCommands()
            coordinator.keyboardUITestReceiveKeyboardEndFrame(docked, isLocal: true)
            await drainMainQueue()
    
            #expect(coordinator.softwareKeyboardPresentation == .hidden)
            #expect(session.accessorySuppressionRequests == [])
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func redockingDoesNotReloadOrRebuildInputSession() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let docked = CGRect(x: 0, y: 650, width: 1_366, height: 374)
            let floating = CGRect(x: 930, y: 620, width: 320, height: 280)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = screen
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            session.resetCommands()
    
            for frame in [docked, floating, docked, floating, floating] {
                coordinator.keyboardUITestReceiveKeyboardEndFrame(frame, isLocal: true)
            }
            await drainMainQueue()
    
            #expect(
                coordinator.softwareKeyboardPresentation
                    == .floating(frame: floating)
            )
            #expect(session.releaseCount == 0)
            #expect(session.acquireCount == 0)
            #expect(session.rebuildCount == 0)
            #expect(session.accessorySuppressionRequests.allSatisfy { !$0 })
            #expect(session.accessoryReloadCount == 0)
        }
    
        @Test
        @MainActor
        func transientDockedFrameDoesNotReattachAccessoryWhileFloatingKeyboardMoves() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let docked = CGRect(x: 0, y: 650, width: 1_366, height: 374)
            let floatingStart = CGRect(x: 930, y: 620, width: 320, height: 280)
            let floatingEnd = CGRect(x: 700, y: 500, width: 320, height: 280)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = screen
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
    
            coordinator.keyboardUITestReceiveKeyboardEndFrame(docked, isLocal: true)
            coordinator.keyboardUITestReceiveKeyboardEndFrame(floatingStart, isLocal: true)
            session.resetCommands()
    
            coordinator.keyboardUITestReceiveKeyboardEndFrame(
                docked,
                isLocal: true
            )
            coordinator.keyboardUITestReceiveKeyboardEndFrame(floatingEnd, isLocal: true)
            await drainMainQueue()
    
            #expect(
                coordinator.softwareKeyboardPresentation
                    == .floating(frame: floatingEnd)
            )
            #expect(session.accessoryReloadCount == 0)
            #expect(session.rebuildCount == 0)
    
            coordinator.keyboardUITestReceiveKeyboardEndFrame(
                docked,
                isLocal: true
            )
            #expect(session.accessoryReloadCount == 0)
    
            coordinator.keyboardUITestReceiveKeyboardEndFrame(docked, isLocal: true)
            #expect(session.accessoryReloadCount == 0)
        }
    
        @Test
        @MainActor
        func transientHiddenFramesDoNotReloadAccessoryWhenRedocking() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let docked = CGRect(x: 0, y: 650, width: 1_366, height: 374)
            let floating = CGRect(x: 930, y: 620, width: 320, height: 280)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.screenFrame = screen
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(docked)
            session.resetCommands()
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(floating)
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(docked)
            await drainMainQueue()
    
            #expect(
                coordinator.softwareKeyboardPresentation
                    == .docked(frame: docked)
            )
            #expect(session.accessorySuppressionRequests.allSatisfy { !$0 })
            #expect(session.accessoryReloadCount == 0)
        }
    
        @Test
        @MainActor
        func sceneActivationKeepsAccessoryAttachedForCurrentFloatingKeyboard() async {
            let paneId = UUID()
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let floating = CGRect(x: 930, y: 620, width: 320, height: 280)
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.keyboardLayoutFrame = floating
            session.snapshot.screenFrame = screen
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            coordinator.activeTerminalSceneWillDeactivate(for: paneId)
            session.resetCommands()
    
            coordinator.activeTerminalSceneDidActivate(for: paneId)
            await drainMainQueue()
    
            #expect(session.accessoryAppearanceRefreshCount == 1)
            #expect(session.accessorySuppressionRequests.last == false)
            #expect(
                coordinator.softwareKeyboardPresentation
                    == .floating(frame: floating)
            )
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.rebuildCount == 0)
        }
    
        @Test
        @MainActor
        func sceneActivationRepairsAcquiredSessionOnceWhenKeyboardNeverPresents() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
            session.snapshot.isFirstResponder = false
            session.snapshot.isSoftwareInputActive = false
            session.resetCommands()
    
            coordinator.activeTerminalSceneDidActivate(for: paneId)
            await drainMainQueue()
    
            #expect(session.acquireCount == 1)
            #expect(session.rebuildCount == 0)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
    
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(session.acquireCount == 2)
            #expect(session.rebuildCount == 1)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
    
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(session.acquireCount == 2)
            #expect(session.rebuildCount == 1)
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.accessorySuppressionRequests == [true])
        }
    
    }
}
#endif
