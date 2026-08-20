#if os(iOS)
import Combine
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct Presentation {
        @Test
        @MainActor
        func automaticSessionAcquisitionDoesNotForceSoftwareKeyboard() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            session.snapshot.isFirstResponder = false
            session.snapshot.isSoftwareInputActive = false
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
    
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()
    
            #expect(session.acquireCount == 1)
            #expect(session.forceSoftwareKeyboardCount == 0)
        }
    
        @Test
        @MainActor
        func losingViewOwnershipClearsObservedKeyboardGeometry() {
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.setViewActive(true)
            coordinator.keyboardUITestSetSoftwareKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300)
            )
    
            #expect(coordinator.softwareKeyboardEndFrame != nil)
    
            coordinator.setViewActive(false)
    
            #expect(coordinator.softwareKeyboardEndFrame == nil)
            #expect(!coordinator.isSoftwareKeyboardVisible)
        }
    
        @Test
        @MainActor
        func routeNavigationRelinquishesOwnershipWithoutSynchronousInputTeardown() async {
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
    
            coordinator.relinquishRouteOwnershipForNavigation()
            await drainMainQueue()
    
            #expect(session.releaseCount == 0)
            #expect(session.rebuildCount == 0)
        }
    
        @Test
        func presentationAlreadyInProgressIsNotRebuilt() {
            #expect(
                TerminalKeyboardCoordinator.presentationRefreshAction(
                    keyboardPresentationDesired: true,
                    refreshRequested: true,
                    windowOwnsInput: true,
                    softwareInputActive: true,
                    softwareKeyboardSuppressed: false,
                    softwareKeyboardVisible: false,
                    presentationVerificationPending: true,
                    refreshAttemptCount: 0,
                    refreshAttemptLimit: 2
                ) == .deferUntilVerification
            )
        }
    
        @Test
        func settledMissingPresentationCanBeRebuiltWithinAttemptLimit() {
            #expect(
                TerminalKeyboardCoordinator.presentationRefreshAction(
                    keyboardPresentationDesired: true,
                    refreshRequested: true,
                    windowOwnsInput: true,
                    softwareInputActive: true,
                    softwareKeyboardSuppressed: false,
                    softwareKeyboardVisible: false,
                    presentationVerificationPending: false,
                    refreshAttemptCount: 0,
                    refreshAttemptLimit: 2
                ) == .rebuild
            )
            #expect(
                TerminalKeyboardCoordinator.presentationRefreshAction(
                    keyboardPresentationDesired: true,
                    refreshRequested: true,
                    windowOwnsInput: true,
                    softwareInputActive: true,
                    softwareKeyboardSuppressed: false,
                    softwareKeyboardVisible: false,
                    presentationVerificationPending: false,
                    refreshAttemptCount: 2,
                    refreshAttemptLimit: 2
                ) == .none
            )
        }
    
        @Test
        func visibleKeyboardSupersedesPendingRefresh() {
            #expect(
                TerminalKeyboardCoordinator.presentationRefreshAction(
                    keyboardPresentationDesired: true,
                    refreshRequested: true,
                    windowOwnsInput: true,
                    softwareInputActive: true,
                    softwareKeyboardSuppressed: false,
                    softwareKeyboardVisible: true,
                    presentationVerificationPending: true,
                    refreshAttemptCount: 0,
                    refreshAttemptLimit: 2
                ) == .none
            )
        }
    
        @Test
        func nonKeyWindowCannotRebuildKeyboardPresentation() {
            #expect(
                TerminalKeyboardCoordinator.presentationRefreshAction(
                    keyboardPresentationDesired: true,
                    refreshRequested: true,
                    windowOwnsInput: false,
                    softwareInputActive: true,
                    softwareKeyboardSuppressed: false,
                    softwareKeyboardVisible: false,
                    presentationVerificationPending: false,
                    refreshAttemptCount: 0,
                    refreshAttemptLimit: 2
                ) == .none
            )
        }
    
        @Test
        func intentionallySuppressedSoftwareKeyboardDoesNotStartPresentationRepair() {
            #expect(
                TerminalKeyboardCoordinator.presentationRefreshAction(
                    keyboardPresentationDesired: true,
                    refreshRequested: true,
                    windowOwnsInput: true,
                    softwareInputActive: true,
                    softwareKeyboardSuppressed: true,
                    softwareKeyboardVisible: false,
                    presentationVerificationPending: false,
                    refreshAttemptCount: 0,
                    refreshAttemptLimit: 2
                ) == .none
            )
        }
    
        @Test
        func keyboardFrameMustBeSubstantiallyVisibleOnActiveScreen() {
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let floating = CGRect(x: 1_000, y: 650, width: 320, height: 280)
    
            #expect(
                TerminalKeyboardCoordinator.visibleKeyboardFrame(
                    floating,
                    in: screen
                ) == floating
            )
            #expect(
                TerminalKeyboardCoordinator.visibleKeyboardFrame(
                    CGRect(x: 0, y: 980, width: 1_366, height: 44),
                    in: screen
                ) == nil
            )
            #expect(
                TerminalKeyboardCoordinator.visibleKeyboardFrame(
                    CGRect(x: 1_500, y: 650, width: 320, height: 280),
                    in: screen
                ) == nil
            )
        }
    
        @Test
        func keyboardPresentationModelsHiddenDockedAndFloatingStatesExplicitly() {
            let screen = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
            let docked = CGRect(x: 0, y: 650, width: 1_366, height: 374)
            let floating = CGRect(x: 930, y: 620, width: 320, height: 280)
    
            #expect(
                TerminalKeyboardCoordinator.softwareKeyboardPresentation(
                    for: nil,
                    in: screen
                ) == .hidden
            )
            #expect(
                TerminalKeyboardCoordinator.softwareKeyboardPresentation(
                    for: docked,
                    in: screen
                ) == .docked(frame: docked)
            )
            #expect(
                TerminalKeyboardCoordinator.softwareKeyboardPresentation(
                    for: floating,
                    in: screen
                ) == .floating(frame: floating)
            )
        }
    
        @Test
        @MainActor
        func directTouchInNonKeyWindowDoesNotStartReacquisition() async {
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
            session.snapshot.windowIsKey = false
    
            coordinator.directTouchOnTerminal()
            await drainMainQueue()
    
            #expect(session.rebuildCount == 0)
            #expect(session.releaseCount == 0)
            #expect(session.acquireCount == 0)
        }
    }
}
#endif
