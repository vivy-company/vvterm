#if os(iOS)
import Combine
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct Rebuild {
        @Test
        @MainActor
        func rebuildCompletionWaitsUntilTerminalWindowBecomesKey() async {
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
    
            session.snapshot.windowIsKey = false
            session.completeNextRebuild()
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 0)
    
            session.snapshot.windowIsKey = true
            coordinator.activeTerminalWindowDidBecomeKey(for: paneId)
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.rebuildCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test(arguments: [false, true])
        @MainActor
        func explicitRebuildSurvivesRouteKeyTransition(
            keyReturnsBeforeCompletion: Bool
        ) async {
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
    
            session.snapshot.windowIsKey = false
            coordinator.setActivePane(nil)
            coordinator.setViewActive(false)
            await drainMainQueue()
    
            if keyReturnsBeforeCompletion {
                session.snapshot.windowIsKey = true
                coordinator.setActivePane(paneId)
                coordinator.setViewActive(true)
                coordinator.activeTerminalWindowDidBecomeKey(for: paneId)
                await drainMainQueue()
                #expect(session.forceSoftwareKeyboardCount == 0)
            }
    
            session.completeNextRebuild()
            await drainMainQueue()
    
            if !keyReturnsBeforeCompletion {
                #expect(session.forceSoftwareKeyboardCount == 0)
                session.snapshot.windowIsKey = true
                coordinator.setActivePane(paneId)
                coordinator.setViewActive(true)
                coordinator.activeTerminalWindowDidBecomeKey(for: paneId)
                await drainMainQueue()
            }
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.rebuildCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func explicitRebuildResumesWhenPaneInputBecomesEligible() async {
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
    
            coordinator.setPaneInputEligible(false, for: paneId)
            session.completeNextRebuild()
            await drainMainQueue()
            #expect(session.forceSoftwareKeyboardCount == 0)
    
            // Focus can return through a direct-touch or hardware-key path while
            // the explicit software-keyboard request waits on SSH eligibility.
            session.snapshot.isFirstResponder = true
            session.snapshot.isSoftwareInputActive = true
            coordinator.setPaneInputEligible(true, for: paneId)
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.rebuildCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func explicitRebuildForcesAfterIndependentReacquisitionBeforeCompletion() async {
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
    
            session.snapshot.isFirstResponder = true
            session.snapshot.isSoftwareInputActive = true
            session.completeNextRebuild()
            await drainMainQueue()
    
            #expect(session.acquireCount == 0)
            #expect(session.forceSoftwareKeyboardCount == 1)
            #expect(session.rebuildCount == 1)
            #expect(session.snapshot.isSoftwareInputActive)
        }
    
        @Test
        @MainActor
        func observedKeyboardHideKeepsAccessoryAttachedUntilPresentationSettles() async {
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
    
            coordinator.userRequestedShow()
            await drainMainQueue()
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            #expect(session.accessorySuppressionRequests == [false])
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
            #expect(session.accessorySuppressionRequests == [false])
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
            #expect(session.accessorySuppressionRequests == [false, false])
            #expect(session.accessoryReloadCount == 0)
        }
    
        @Test
        @MainActor
        func missingInitialKeyboardSuppressesAccessoryAfterPresentationSettles() async {
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
    
            coordinator.userRequestedShow()
            await drainMainQueue()
            session.resetCommands()
    
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(nil)
    
            #expect(session.accessorySuppressionRequests.isEmpty)
            #expect(coordinator.keyboardUITestPresentationVerificationPending)
    
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            await drainMainQueue()
    
            #expect(session.accessorySuppressionRequests == [true])
        }
    
    }
}
#endif
