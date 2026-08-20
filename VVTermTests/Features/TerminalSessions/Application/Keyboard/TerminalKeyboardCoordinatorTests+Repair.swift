#if os(iOS)
import Combine
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct Repair {
        @Test
        @MainActor
        func terminalReplacementReconcilesNewOwnerAndCancelsOldVerification() async {
            let paneId = UUID()
            let originalSession = TerminalKeyboardInputSessionSpy()
            let replacementSession = TerminalKeyboardInputSessionSpy()
            replacementSession.snapshot.windowAttached = false
            replacementSession.snapshot.windowIsKey = false
            replacementSession.snapshot.isFirstResponder = false
            replacementSession.snapshot.isSoftwareInputActive = false
            var providedSession = originalSession
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? providedSession : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
    
            coordinator.userRequestedHide()
            await drainMainQueue()
            originalSession.resetCommands()
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(originalSession.forceSoftwareKeyboardCount == 1)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
    
            providedSession = replacementSession
            coordinator.setWindowAttached(false, for: paneId)
            coordinator.terminalProviderIdentityDidChange(for: paneId)
            await drainMainQueue()
    
            #expect(replacementSession.acquireCount == 0)
            #expect(replacementSession.forceSoftwareKeyboardCount == 0)
            #expect(replacementSession.rebuildCount == 0)
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
    
            replacementSession.snapshot.windowAttached = true
            replacementSession.snapshot.windowIsKey = true
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
    
            #expect(replacementSession.acquireCount == 1)
            #expect(replacementSession.forceSoftwareKeyboardCount == 0)
            #expect(replacementSession.rebuildCount == 0)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
            await drainMainQueue()
    
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
            #expect(originalSession.forceSoftwareKeyboardCount == 1)
            #expect(originalSession.rebuildCount == 0)
            #expect(originalSession.accessorySuppressionRequests.isEmpty)
            #expect(replacementSession.acquireCount == 1)
            #expect(replacementSession.forceSoftwareKeyboardCount == 0)
            #expect(replacementSession.rebuildCount == 0)
            #expect(replacementSession.accessorySuppressionRequests == [false])
        }
    
        @Test
        @MainActor
        func explicitShowBeginsOnePresentationWithoutRebuildingActiveInput() async {
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
            session.resetCommands()
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.rebuildCount == 0)
        }
    
        @Test
        @MainActor
        func explicitShowRepairsUnexpectedlyMissingKeyboardImmediately() async {
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
    
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.rebuildCount == 1)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.accessorySuppressionRequests.isEmpty)
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
    
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.rebuildCount == 1)
            #expect(session.accessorySuppressionRequests == [false])
        }
    
        @Test
        @MainActor
        func explicitRepairRetriesWhenResponderReacquisitionFails() async {
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
            session.forceSoftwareKeyboardResults = [false, true]
    
            coordinator.userRequestedShow()
            await drainMainQueue()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 2)
            #expect(session.snapshot.isSoftwareInputActive)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
        }
    
        @Test
        @MainActor
        func explicitReacquisitionFailuresStopAtAttemptLimit() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.forceSoftwareKeyboardResults = [false, false, true]
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
            await drainMainQueue()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 2)
            #expect(!session.snapshot.isSoftwareInputActive)
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.accessorySuppressionRequests == [true])
        }
    
        @Test
        @MainActor
        func automaticReacquisitionFailuresStopAtAttemptLimit() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.acquireResults = [false, false, true]
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
            await drainMainQueue()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 1)
            #expect(session.acquireCount == 2)
            #expect(!session.snapshot.isSoftwareInputActive)
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.accessorySuppressionRequests == [true])
        }
    
        @Test
        @MainActor
        func findRelinquishingOwnershipStartsFreshAfterRepairBudgetIsExhausted() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.acquireResults = [false, false]
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
            await drainMainQueue()
            await drainMainQueue()
    
            #expect(session.acquireCount == 2)
            #expect(!session.snapshot.isSoftwareInputActive)
    
            // UIFindInteraction may resign the terminal before its visibility
            // callback reaches the coordinator. That leaves input already absent
            // when Find takes ownership, so the normal release branch cannot be
            // relied on to reset a stale presentation-repair budget.
            coordinator.setFindNavigatorActive(true, for: paneId)
            await drainMainQueue()
            session.resetCommands()
            session.acquireResults = [true]
    
            coordinator.setFindNavigatorActive(false, for: paneId)
            await drainMainQueue()
    
            #expect(session.acquireCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func rebuildCompletionDoesNotReacquireReplacedTerminal() async {
            let paneId = UUID()
            let originalSession = TerminalKeyboardInputSessionSpy()
            originalSession.completesRebuildImmediately = false
            let replacementSession = TerminalKeyboardInputSessionSpy()
            var providedSession = originalSession
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? providedSession : nil
            }
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
            originalSession.resetCommands()
    
            coordinator.userRequestedShow()
            await drainMainQueue()
            #expect(originalSession.rebuildCount == 1)
    
            providedSession = replacementSession
            originalSession.completeNextRebuild()
            await drainMainQueue()
    
            #expect(originalSession.forceSoftwareKeyboardCount == 0)
            #expect(!originalSession.snapshot.isSoftwareInputActive)
            #expect(replacementSession.acquireCount == 0)
        }
    
        @Test
        @MainActor
        func routeModalDeactivationPreventsDelayedRebuildFromReacquiringInput() async {
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
    
            coordinator.userRequestedShow()
            await drainMainQueue()
            #expect(session.rebuildCount == 1)
    
            coordinator.deactivateInputImmediately(reason: .routeModal)
            session.completeNextRebuild()
            await drainMainQueue()
    
            #expect(session.forceSoftwareKeyboardCount == 0)
            #expect(!session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func routeModalDeactivationReleasesInputAndCancelsPresentationVerification() async {
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
            session.resetCommands()
            coordinator.userRequestedShow()
            await drainMainQueue()
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
            let forceSoftwareKeyboardCount = session.forceSoftwareKeyboardCount
    
            coordinator.deactivateInputImmediately(reason: .routeModal)
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(!coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.releaseCount == 1)
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == forceSoftwareKeyboardCount)
            #expect(session.accessorySuppressionRequests == [true])
            #expect(!session.snapshot.isFirstResponder)
            #expect(!session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func routeModalRoundTripPreservesUserHiddenKeyboardIntent() async {
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
            coordinator.deactivateInputImmediately(reason: .routeModal)
            session.resetCommands()
    
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            await drainMainQueue()
    
            #expect(coordinator.isUserHidden)
            #expect(session.focusWithoutSoftwareKeyboardCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 0)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func contentProtectionRoundTripReplaysSceneActivationRecovery() async {
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
    
            coordinator.deactivateInputImmediately()
            await drainMainQueue()
            session.resetCommands()
    
            // This mirrors the route becoming visible after biometric unlock:
            // first reacquire ownership, then replay the foreground scene
            // recovery that reconciles UIKit's keyboard scene.
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            await drainMainQueue()
            coordinator.activeTerminalContentDidBecomeVisible(for: paneId)
            await drainMainQueue()
    
            #expect(session.accessoryAppearanceRefreshCount == 1)
            #expect(session.accessorySuppressionRequests.last == false)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
            #expect(session.rebuildCount == 1)
    
            coordinator.activeTerminalContentDidBecomeVisible(for: paneId)
            await drainMainQueue()
            #expect(session.rebuildCount == 1)
    
            coordinator.activeTerminalSceneWillDeactivate(for: paneId)
            coordinator.activeTerminalContentDidBecomeVisible(for: paneId)
            await drainMainQueue()
            #expect(session.rebuildCount == 2)
    
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(session.rebuildCount == 2)
        }
    
        @Test
        @MainActor
        func newerExplicitRequestSupersedesDelayedAutomaticReacquisition() async {
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
    
            coordinator.userRequestedShow()
            session.completeNextRebuild()
            await drainMainQueue()
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.rebuildCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
        }
    
        @Test
        @MainActor
        func paneSwitchDoesNotTransferDeferredExplicitRequest() async {
            let originalPaneId = UUID()
            let nextPaneId = UUID()
            let originalSession = TerminalKeyboardInputSessionSpy()
            let nextSession = TerminalKeyboardInputSessionSpy()
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
    
            coordinator.setFindNavigatorActive(true, for: originalPaneId)
            await drainMainQueue()
            coordinator.userRequestedShow()
            await drainMainQueue()
    
            coordinator.setActivePane(nextPaneId)
            coordinator.setFindNavigatorActive(false, for: nextPaneId)
            await drainMainQueue()
    
            #expect(nextSession.forceSoftwareKeyboardCount == 0)
        }
    
        @Test
        @MainActor
        func repeatedPaneFocusTransfersResponderWithoutInputUITeardown() async {
            let firstPaneId = UUID()
            let secondPaneId = UUID()
            let firstSession = TerminalKeyboardInputSessionSpy()
            let secondSession = TerminalKeyboardInputSessionSpy()
            secondSession.snapshot.isFirstResponder = false
            secondSession.snapshot.isSoftwareInputActive = false
            firstSession.snapshot.keyboardLayoutFrame = CGRect(
                x: 0,
                y: 700,
                width: 1_024,
                height: 300
            )
            secondSession.snapshot.keyboardLayoutFrame = firstSession.snapshot.keyboardLayoutFrame
            firstSession.snapshot.screenFrame = CGRect(x: 0, y: 0, width: 1_024, height: 1_000)
            secondSession.snapshot.screenFrame = firstSession.snapshot.screenFrame
            firstSession.onAcquire = {
                secondSession.snapshot.isFirstResponder = false
                secondSession.snapshot.isSoftwareInputActive = false
            }
            secondSession.onAcquire = {
                firstSession.snapshot.isFirstResponder = false
                firstSession.snapshot.isSoftwareInputActive = false
            }
    
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { paneId in
                switch paneId {
                case firstPaneId: firstSession
                case secondPaneId: secondSession
                default: nil
                }
            }
            coordinator.setPaneInputEligible(true, for: firstPaneId)
            coordinator.setWindowAttached(true, for: firstPaneId)
            coordinator.setPaneInputEligible(true, for: secondPaneId)
            coordinator.setWindowAttached(true, for: secondPaneId)
            coordinator.setViewActive(true)
            coordinator.setActivePane(firstPaneId)
            await drainMainQueue()
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            firstSession.resetCommands()
            secondSession.resetCommands()
    
            for index in 0..<20 {
                coordinator.setActivePane(index.isMultiple(of: 2) ? secondPaneId : firstPaneId)
                await drainMainQueue()
            }
    
            #expect(firstSession.releaseCount == 0)
            #expect(secondSession.releaseCount == 0)
            #expect(firstSession.acquireCount == 10)
            #expect(secondSession.acquireCount == 10)
            #expect(firstSession.accessoryReloadCount == 0)
            #expect(secondSession.accessoryReloadCount == 0)
            #expect(coordinator.isSoftwareKeyboardVisible)
        }
    
    }
}
#endif
