#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@MainActor
struct TerminalPointerInputRoutingPolicyTests {
    @Test
    func mapsPrimaryButtonToLeftMouseButton() {
        #expect(
            TerminalPointerInputRoutingPolicy.pointerButton(
                isPrimaryPressed: true,
                isSecondaryPressed: false,
                isMiddlePressed: false,
                hasControlModifier: false
            ) == .left
        )
    }

    @Test
    func mapsSecondaryButtonToRightMouseButton() {
        #expect(
            TerminalPointerInputRoutingPolicy.pointerButton(
                isPrimaryPressed: false,
                isSecondaryPressed: true,
                isMiddlePressed: false,
                hasControlModifier: false
            ) == .right
        )
    }

    @Test
    func mapsControlPrimaryClickToRightMouseButton() {
        #expect(
            TerminalPointerInputRoutingPolicy.pointerButton(
                isPrimaryPressed: true,
                isSecondaryPressed: false,
                isMiddlePressed: false,
                hasControlModifier: true
            ) == .right
        )
    }

    @Test
    func mapsThirdPointerButtonToMiddleMouseButton() {
        #expect(
            TerminalPointerInputRoutingPolicy.pointerButton(
                isPrimaryPressed: false,
                isSecondaryPressed: false,
                isMiddlePressed: true,
                hasControlModifier: false
            ) == .middle
        )
    }

    @Test
    func ignoresPointerEventsWithoutPressedButtons() {
        #expect(
            TerminalPointerInputRoutingPolicy.pointerButton(
                isPrimaryPressed: false,
                isSecondaryPressed: false,
                isMiddlePressed: false,
                hasControlModifier: false
            ) == nil
        )
    }

    @Test
    func convertsPointerKeyboardModifiersToGhosttyModifiers() {
        let flags: UIKeyModifierFlags = [.shift, .control, .alternate, .command]
        let mods = Ghostty.Input.Mods(uiKeyModifiers: flags)

        #expect(mods.contains(.shift))
        #expect(mods.contains(.ctrl))
        #expect(mods.contains(.alt))
        #expect(mods.contains(.super))
    }

    @Test
    func showsHostContextMenuOnlyForUnhandledUncapturedRightClick() {
        #expect(
            TerminalPointerInputRoutingPolicy.shouldShowHostContextMenu(
                button: .right,
                terminalHandledButtonPress: false,
                terminalMouseCaptured: false
            )
        )

        #expect(
            TerminalPointerInputRoutingPolicy.shouldShowHostContextMenu(
                button: .left,
                terminalHandledButtonPress: false,
                terminalMouseCaptured: false
            ) == false
        )

        #expect(
            TerminalPointerInputRoutingPolicy.shouldShowHostContextMenu(
                button: .right,
                terminalHandledButtonPress: true,
                terminalMouseCaptured: false
            ) == false
        )

        #expect(
            TerminalPointerInputRoutingPolicy.shouldShowHostContextMenu(
                button: .right,
                terminalHandledButtonPress: false,
                terminalMouseCaptured: true
            ) == false
        )
    }

    @Test
    func allowsFingerDragToScroll() {
        #expect(
            TerminalPointerInputRoutingPolicy.shouldAllowScrollGesture(
                isIndirectPointer: false,
                isPointerButtonPressed: true,
                hasActiveTerminalPointerButton: true
            )
        )
    }

    @Test
    func allowsButtonlessIndirectPointerScroll() {
        #expect(
            TerminalPointerInputRoutingPolicy.shouldAllowScrollGesture(
                isIndirectPointer: true,
                isPointerButtonPressed: false,
                hasActiveTerminalPointerButton: false
            )
        )
    }

    @Test
    func blocksIndirectPointerButtonDragFromScrollRecognizer() {
        #expect(
            TerminalPointerInputRoutingPolicy.shouldAllowScrollGesture(
                isIndirectPointer: true,
                isPointerButtonPressed: true,
                hasActiveTerminalPointerButton: false
            ) == false
        )

        #expect(
            TerminalPointerInputRoutingPolicy.shouldAllowScrollGesture(
                isIndirectPointer: true,
                isPointerButtonPressed: false,
                hasActiveTerminalPointerButton: true
            ) == false
        )
    }

    @Test
    func routesDirectTouchClickToAvailableCapturedTerminal() {
        #expect(
            TerminalPointerInputRoutingPolicy.shouldSendDirectTouchClick(
                terminalMouseCaptured: true,
                terminalInputAvailable: true,
                selectionInteractionActive: false
            )
        )
    }

    @Test
    func doesNotRouteDirectTouchClickOutsideMouseCapture() {
        #expect(
            !TerminalPointerInputRoutingPolicy.shouldSendDirectTouchClick(
                terminalMouseCaptured: false,
                terminalInputAvailable: true,
                selectionInteractionActive: false
            )
        )
    }

    @Test
    func excludesSelectionInteractionFromDirectTouchClick() {
        #expect(
            !TerminalPointerInputRoutingPolicy.shouldSendDirectTouchClick(
                terminalMouseCaptured: true,
                terminalInputAvailable: true,
                selectionInteractionActive: true
            )
        )
    }

    @Test
    func excludesUnavailableTerminalInputFromDirectTouchClick() {
        #expect(
            !TerminalPointerInputRoutingPolicy.shouldSendDirectTouchClick(
                terminalMouseCaptured: true,
                terminalInputAvailable: false,
                selectionInteractionActive: false
            )
        )
    }

    @Test
    func allowsInactiveHostSelectionOnlyOutsideTerminalMouseCapture() {
        #expect(
            TerminalSelectionRoutingPolicy.shouldAllowHostSelection(
                terminalMouseCaptured: false,
                selectionInteractionActive: false
            )
        )

        #expect(
            TerminalSelectionRoutingPolicy.shouldAllowHostSelection(
                terminalMouseCaptured: true,
                selectionInteractionActive: false
            ) == false
        )
    }

    @Test
    func activeSelectionKeepsHostSelectionAvailableDuringTerminalMouseCapture() {
        #expect(
            TerminalSelectionRoutingPolicy.shouldAllowHostSelection(
                terminalMouseCaptured: true,
                selectionInteractionActive: true
            )
        )
    }

    @Test
    func doesNotAutoscrollSelectionAwayFromVerticalEdges() {
        #expect(
            TerminalSelectionAutoscrollPolicy.decision(
                locationY: 200,
                viewportHeight: 500,
                edgeInset: 50,
                maximumScrollDelta: 12
            ) == nil
        )
    }

    @Test
    func autoscrollsSelectionTowardOlderHistoryAtTopEdge() {
        let decision = TerminalSelectionAutoscrollPolicy.decision(
            locationY: 10,
            viewportHeight: 500,
            edgeInset: 50,
            maximumScrollDelta: 12
        )

        #expect(decision?.edge == .top)
        #expect(decision?.scrollDelta ?? 0 > 0)
    }

    @Test
    func autoscrollsSelectionTowardNewerHistoryAtBottomEdge() {
        let decision = TerminalSelectionAutoscrollPolicy.decision(
            locationY: 490,
            viewportHeight: 500,
            edgeInset: 50,
            maximumScrollDelta: 12
        )

        #expect(decision?.edge == .bottom)
        #expect(decision?.scrollDelta ?? 0 < 0)
    }
}
#endif
