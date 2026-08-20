#if os(iOS)
import Combine
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

extension TerminalKeyboardCoordinatorTests {
    @Suite(.serialized)
    struct InputPolicy {
        @Test
        func reconnectInputEligibilityRequiresPriorTypingIntent() {
            #expect(TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: .connected,
                shouldRestoreOnReconnect: false
            ))
            #expect(!TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: .connecting,
                shouldRestoreOnReconnect: false
            ))
            #expect(TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: .reconnecting(attempt: 1),
                shouldRestoreOnReconnect: true
            ))
            #expect(!TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: .disconnected,
                shouldRestoreOnReconnect: true
            ))
        }
    
        @Test
        func desiredInputSessionAndKeyboardPresentationContract() {
            struct Case {
                let name: String
                let inputs: TerminalKeyboardCoordinator.StateInputs
                let expectedInputSessionActive: Bool
                let expectedKeyboardVisible: Bool
            }
    
            let visible = TerminalKeyboardCoordinator.StateInputs(
                viewActive: true,
                activePaneInputEligible: true,
                activePaneWindowAttached: true,
                allowsLocalInputOwnership: true,
                userHidKeyboard: false,
                findNavigatorActive: false
            )
    
            let cases = [
                Case(
                    name: "connected active attached",
                    inputs: visible,
                    expectedInputSessionActive: true,
                    expectedKeyboardVisible: true
                ),
                Case(
                    name: "user hidden",
                    inputs: .init(
                        viewActive: true,
                        activePaneInputEligible: true,
                        activePaneWindowAttached: true,
                        allowsLocalInputOwnership: true,
                        userHidKeyboard: true,
                        findNavigatorActive: false
                    ),
                    expectedInputSessionActive: true,
                    expectedKeyboardVisible: false
                ),
                Case(
                    name: "user shown again",
                    inputs: visible,
                    expectedInputSessionActive: true,
                    expectedKeyboardVisible: true
                ),
                Case(
                    name: "left terminal view",
                    inputs: .init(
                        viewActive: false,
                        activePaneInputEligible: true,
                        activePaneWindowAttached: true,
                        allowsLocalInputOwnership: true,
                        userHidKeyboard: false,
                        findNavigatorActive: false
                    ),
                    expectedInputSessionActive: false,
                    expectedKeyboardVisible: false
                ),
                Case(
                    name: "window not attached",
                    inputs: .init(
                        viewActive: true,
                        activePaneInputEligible: true,
                        activePaneWindowAttached: false,
                        allowsLocalInputOwnership: true,
                        userHidKeyboard: false,
                        findNavigatorActive: false
                    ),
                    expectedInputSessionActive: false,
                    expectedKeyboardVisible: false
                ),
                Case(
                    name: "window attached after mount",
                    inputs: visible,
                    expectedInputSessionActive: true,
                    expectedKeyboardVisible: true
                ),
                Case(
                    name: "find navigator active",
                    inputs: .init(
                        viewActive: true,
                        activePaneInputEligible: true,
                        activePaneWindowAttached: true,
                        allowsLocalInputOwnership: true,
                        userHidKeyboard: false,
                        findNavigatorActive: true
                    ),
                    expectedInputSessionActive: false,
                    expectedKeyboardVisible: false
                ),
                Case(
                    name: "reconnect restores when visible before",
                    inputs: visible,
                    expectedInputSessionActive: true,
                    expectedKeyboardVisible: true
                ),
                Case(
                    name: "reconnect stays hidden when hidden before",
                    inputs: .init(
                        viewActive: true,
                        activePaneInputEligible: true,
                        activePaneWindowAttached: true,
                        allowsLocalInputOwnership: true,
                        userHidKeyboard: true,
                        findNavigatorActive: false
                    ),
                    expectedInputSessionActive: true,
                    expectedKeyboardVisible: false
                ),
                Case(
                    name: "external app owns input",
                    inputs: .init(
                        viewActive: true,
                        activePaneInputEligible: true,
                        activePaneWindowAttached: true,
                        allowsLocalInputOwnership: false,
                        userHidKeyboard: false,
                        findNavigatorActive: false
                    ),
                    expectedInputSessionActive: false,
                    expectedKeyboardVisible: false
                ),
            ]
    
            for testCase in cases {
                #expect(
                    TerminalKeyboardCoordinator.desiredInputSessionActive(inputs: testCase.inputs) == testCase.expectedInputSessionActive,
                    "\(testCase.name) input session"
                )
                #expect(
                    TerminalKeyboardCoordinator.desiredKeyboardVisible(inputs: testCase.inputs) == testCase.expectedKeyboardVisible,
                    "\(testCase.name) keyboard presentation"
                )
            }
        }
    
        @Test
        @MainActor
        func directTouchDoesNotRestoreKeyboardAfterUserHide() {
            let coordinator = TerminalKeyboardCoordinator()
    
            coordinator.userRequestedHide()
            #expect(coordinator.isUserHidden)
    
            coordinator.directTouchOnTerminal(isFocusTap: false)
            #expect(coordinator.isUserHidden)
    
            coordinator.directTouchOnTerminal(isFocusTap: true)
            #expect(coordinator.isUserHidden)
        }
    
        @Test
        @MainActor
        func repeatedAccessoryDismissRepublishesHiddenState() {
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.userRequestedHide()
    
            var publicationCount = 0
            let observation = coordinator.objectWillChange.sink {
                publicationCount += 1
            }
    
            coordinator.userRequestedHide()
    
            #expect(coordinator.isUserHidden)
            #expect(publicationCount > 0)
            _ = observation
        }

        @Test
        @MainActor
        func userHiddenModeRejectsVisibleKeyboardFrames() async {
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

            coordinator.keyboardUITestReceiveKeyboardEndFrame(
                CGRect(x: 0, y: 700, width: 1_024, height: 300),
                isLocal: true
            )
            await drainMainQueue()

            #expect(coordinator.softwareKeyboardPresentation == .hidden)
            #expect(coordinator.isUserHidden)
            #expect(session.forceSoftwareKeyboardCount == 0)
            #expect(session.rebuildCount == 0)
        }

        @Test
        @MainActor
        func userHiddenModeMovesAnActiveReplacementSessionIntoBrowseMode() async {
            let paneId = UUID()
            let session = TerminalKeyboardInputSessionSpy()
            let coordinator = TerminalKeyboardCoordinator()
            coordinator.terminalProvider = { requestedPaneId in
                requestedPaneId == paneId ? session : nil
            }
            coordinator.userRequestedHide()
            coordinator.setActivePane(paneId)
            coordinator.setViewActive(true)
            coordinator.setPaneInputEligible(true, for: paneId)
            coordinator.setWindowAttached(true, for: paneId)
            await drainMainQueue()

            #expect(coordinator.isUserHidden)
            #expect(session.focusWithoutSoftwareKeyboardCount == 1)
            #expect(session.snapshot.isKeyboardInBrowseMode)
            #expect(session.snapshot.isSoftwareKeyboardSuppressed)
            #expect(session.forceSoftwareKeyboardCount == 0)
        }
    
        @Test
        @MainActor
        func explicitShowRestoresKeyboardAfterUserHide() {
            let coordinator = TerminalKeyboardCoordinator()
    
            coordinator.userRequestedHide()
            #expect(coordinator.isUserHidden)
    
            coordinator.userRequestedShow()
            #expect(!coordinator.isUserHidden)
        }
    
    }
}
#endif
