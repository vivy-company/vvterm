#if os(iOS)
import Combine
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct HardwareAndFind {
        @Test
        @MainActor
        func hardwareSuppressionClearsStaleDockedKeyboardPresentationWithoutReload() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.keyboardLayoutFrame = CGRect(
                x: 0,
                y: 700,
                width: 1_024,
                height: 300
            )
            session.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1_024, height: 1_000)
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
            #expect(coordinator.isSoftwareKeyboardVisible)
    
            session.resetCommands()
            session.snapshot.isSoftwareKeyboardSuppressed = true
            coordinator.keyboardUITestReceiveKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300),
                isLocal: true
            )
            await drainMainQueue()
    
            #expect(coordinator.isSoftwareKeyboardVisible == false)
            #expect(session.accessoryReloadCount == 0)
            #expect(coordinator.keyboardUITestPresentationVerificationPending == false)
        }
    
        @Test
        func keyboardNotificationsRejectFramesFromAnotherScreen() {
            let activeScreen = NSObject()
            let otherScreen = NSObject()
    
            #expect(TerminalKeyboardCoordinator.keyboardNotificationMatchesActiveScreen(
                sourceScreenIdentifier: nil,
                activeScreenIdentifier: ObjectIdentifier(activeScreen)
            ))
            #expect(TerminalKeyboardCoordinator.keyboardNotificationMatchesActiveScreen(
                sourceScreenIdentifier: ObjectIdentifier(activeScreen),
                activeScreenIdentifier: ObjectIdentifier(activeScreen)
            ))
            #expect(!TerminalKeyboardCoordinator.keyboardNotificationMatchesActiveScreen(
                sourceScreenIdentifier: ObjectIdentifier(otherScreen),
                activeScreenIdentifier: ObjectIdentifier(activeScreen)
            ))
        }
    
        @Test
        @MainActor
        func suppressedKeyboardInputViewUsesSelfSizingWithoutRequiredHeightConstraint() {
            let inputView = TerminalSuppressedKeyboardInputView()
    
            #expect(inputView.allowsSelfSizing)
            #expect(inputView.constraints.isEmpty)
            #expect(inputView.intrinsicContentSize == .zero)
            #expect(inputView.systemLayoutSizeFitting(.zero) == .zero)
        }
    
        @Test
        @MainActor
        func findUpdateFromInactivePaneDoesNotReleaseActiveTerminal() async {
            let activePaneId = UUID()
            let backgroundPaneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == activePaneId ? session : nil
            }
            coordinator.setActivePane(activePaneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: activePaneId)
            coordinator.setWindowAttached(true, for: activePaneId)
            await drainMainQueue()
            session.resetCommands()
    
            coordinator.setFindNavigatorActive(true, for: backgroundPaneId)
            await drainMainQueue()
    
            #expect(session.releaseCount == 0)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func obsoleteCompletionDoesNotReacquireOldTerminalOrExceedNewPaneBudget() async {
            let originalPaneId = UUID()
            let nextPaneId = UUID()
            let originalSession = TerminalKeyboardInputSessionSpy()
            originalSession.completesRebuildImmediately = false
            let nextSession = TerminalKeyboardInputSessionSpy()
            nextSession.snapshot.isFirstResponder = false
            nextSession.snapshot.isSoftwareInputActive = false
            nextSession.acquireResults = [false, false, true]
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                switch requestedPaneId {
                case originalPaneId: originalSession
                case nextPaneId: nextSession
                default: nil
                }
            }
            coordinator.setActivePane(originalPaneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: originalPaneId)
            coordinator.setWindowAttached(true, for: originalPaneId)
            coordinator.setPaneInputEligible(true, for: nextPaneId)
            coordinator.setWindowAttached(true, for: nextPaneId)
            await drainMainQueue()
    
            coordinator.directTouchOnTerminal()
            await drainMainQueue()
            #expect(originalSession.rebuildCount == 1)
    
            coordinator.setActivePane(nextPaneId)
            originalSession.completeNextRebuild()
            await drainMainQueue()
            await drainMainQueue()
            await drainMainQueue()
    
            #expect(originalSession.acquireCount == 0)
            // The new ownership session gets one ordinary acquisition plus two
            // capped repair attempts. The obsolete completion must not add a
            // fourth attempt or reacquire the old terminal.
            #expect(nextSession.acquireCount == 3)
            #expect(nextSession.snapshot.isSoftwareInputActive)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
        }
    
        @Test
        @MainActor
        func observedResponderStateOverridesUIKitReturnValue() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.forceSoftwareKeyboardResults = [false]
            session.forceSoftwareKeyboardObservedStates = [true]
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
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
        }
    
        @Test
        @MainActor
        func explicitRepairSurvivesStaleKeyboardFrameBeforeQueuedSync() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.keyboardLayoutFrame = CGRect(
                x: 0,
                y: 700,
                width: 1_024,
                height: 300
            )
            session.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1_024, height: 1_000)
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
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func explicitShowDuringReconnectForcesSoftwareKeyboardWhenSessionReturns() async {
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
    
            coordinator.userRequestedHide()
            await drainMainQueue()
            coordinator.setPaneInputEligible(false, for: paneId)
            await drainMainQueue()
            session.resetCommands()
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.forceSoftwareKeyboardCount == 0)
    
            coordinator.setPaneInputEligible(true, for: paneId)
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
        }
    
        @Test
        @MainActor
        func explicitShowWaitsForFindToRelinquishInputOwnership() async {
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
    
            coordinator.setFindNavigatorActive(true, for: paneId)
            await drainMainQueue()
            session.resetCommands()
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.forceSoftwareKeyboardCount == 0)
    
            coordinator.setFindNavigatorActive(false, for: paneId)
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.rebuildCount == 0)
        }
    
        @Test
        @MainActor
        func explicitShowAfterFindRebuildsSessionWhenFindKeyboardMasksTerminalLoss() async {
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
    
            // UIFindInteraction can take the responder before its visibility
            // callback reaches the coordinator. The terminal's broken software
            // input presentation survives that ordinary ownership handoff and is
            // cleared only by a real input-session rebuild.
            session.snapshot.isFirstResponder = false
            session.snapshot.isSoftwareInputActive = false
            coordinator.setFindNavigatorActive(true, for: paneId)
            await drainMainQueue()
            session.resetCommands()
    
            // The Find field's keyboard is still globally visible when the user
            // chooses Keyboard and the terminal retakes input. It must not count
            // as proof that the terminal's own software-input session recovered.
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            coordinator.userRequestedShow()
            await drainMainQueue()
            coordinator.setFindNavigatorActive(false, for: paneId)
            await drainMainQueue()
    
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
            #expect(session.rebuildCount == 1)
        }
    
        @Test
        @MainActor
        func explicitShowRepairsTerminalAfterFindDismissalMaskedItsMissingKeyboard() async {
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
    
            session.snapshot.isFirstResponder = false
            session.snapshot.isSoftwareInputActive = false
            coordinator.setFindNavigatorActive(true, for: paneId)
            await drainMainQueue()
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            coordinator.setFindNavigatorActive(false, for: paneId)
            await drainMainQueue()
    
            // Returning from Find can reacquire the proxy while its still-visible
            // keyboard frame masks the broken terminal input view.
            #expect(session.snapshot.isSoftwareInputActive)
            session.resetCommands()
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func explicitShowPreservesKnownFindRepairAfterUserHide() async {
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
    
            session.snapshot.isFirstResponder = false
            session.snapshot.isSoftwareInputActive = false
            coordinator.setFindNavigatorActive(true, for: paneId)
            await drainMainQueue()
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            coordinator.setFindNavigatorActive(false, for: paneId)
            await drainMainQueue()
    
            coordinator.userRequestedHide()
            await drainMainQueue()
            session.resetCommands()
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
    }
}
#endif
