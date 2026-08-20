import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalNativeSelectionLifecycleTests {
    @Test
    func keepsSelectionAfterInteractionEnds() {
        var lifecycle = TerminalNativeSelectionLifecycle()
        let selection = NSRange(location: 4, length: 7)

        lifecycle.prepare(restoreTerminalInput: true)
        lifecycle.beginInteraction(restoreTerminalInput: false)
        #expect(lifecycle.setSelection(selection) == nil)
        #expect(lifecycle.endInteraction() == nil)

        #expect(lifecycle.phase == .selected(range: selection, restoreTerminalInput: true))
        #expect(lifecycle.keepsFirstResponder)
        #expect(!lifecycle.interactionIsActive)
    }

    @Test
    func requestsTerminalInputRestorationAfterEmptyInteraction() {
        var lifecycle = TerminalNativeSelectionLifecycle()
        let restorationID = UUID()

        lifecycle.prepare(restoreTerminalInput: true)
        lifecycle.beginInteraction(restoreTerminalInput: false)

        #expect(lifecycle.endInteraction(restorationID: restorationID) == restorationID)
        #expect(lifecycle.phase == .restoringTerminalInput(id: restorationID))
        let didRestore = lifecycle.completeRestoration(id: restorationID)
        #expect(didRestore)
        #expect(lifecycle.phase == .inactive)
    }

    @Test
    func zeroLengthSelectionRestoresTerminalInputAfterInteractionEnds() {
        var lifecycle = TerminalNativeSelectionLifecycle()
        let restorationID = UUID()

        lifecycle.prepare(restoreTerminalInput: true)
        lifecycle.beginInteraction(restoreTerminalInput: false)
        let restorationFromSelection = lifecycle.setSelection(
            NSRange(location: 4, length: 0)
        )
        #expect(restorationFromSelection == nil)

        let completedRestorationID = lifecycle.endInteraction(
            restorationID: restorationID
        )
        #expect(completedRestorationID == restorationID)
        #expect(lifecycle.phase == .restoringTerminalInput(id: restorationID))
        let didRestore = lifecycle.completeRestoration(id: restorationID)
        #expect(didRestore)
        #expect(lifecycle.phase == .inactive)
    }

    @Test
    func ignoresStaleRestorationAfterNewSelectionStarts() {
        var lifecycle = TerminalNativeSelectionLifecycle()
        let staleRestorationID = UUID()

        lifecycle.prepare(restoreTerminalInput: true)
        lifecycle.beginInteraction(restoreTerminalInput: false)
        #expect(lifecycle.endInteraction(restorationID: staleRestorationID) == staleRestorationID)

        lifecycle.prepare(restoreTerminalInput: false)

        let didRestore = lifecycle.completeRestoration(id: staleRestorationID)
        #expect(!didRestore)
        #expect(lifecycle.phase == .prepared(selection: nil, restoreTerminalInput: false))
    }

    @Test
    func clearingSelectedTextRestoresTerminalInputOnce() {
        var lifecycle = TerminalNativeSelectionLifecycle()
        let selection = NSRange(location: 2, length: 3)
        let restorationID = UUID()

        lifecycle.prepare(restoreTerminalInput: true)
        lifecycle.beginInteraction(restoreTerminalInput: false)
        #expect(lifecycle.setSelection(selection) == nil)
        #expect(lifecycle.endInteraction() == nil)

        #expect(lifecycle.setSelection(nil, restorationID: restorationID) == restorationID)
        #expect(lifecycle.setSelection(nil) == nil)
        let didRestore = lifecycle.completeRestoration(id: restorationID)
        #expect(didRestore)
    }

    @Test
    func zeroLengthReplacementRestoresTerminalInputFromSelectedState() {
        var lifecycle = TerminalNativeSelectionLifecycle()
        let selection = NSRange(location: 2, length: 3)
        let restorationID = UUID()

        lifecycle.prepare(restoreTerminalInput: true)
        lifecycle.beginInteraction(restoreTerminalInput: false)
        #expect(lifecycle.setSelection(selection) == nil)
        #expect(lifecycle.endInteraction() == nil)

        let completedRestorationID = lifecycle.setSelection(
            NSRange(location: selection.location, length: 0),
            restorationID: restorationID
        )
        #expect(completedRestorationID == restorationID)
        #expect(lifecycle.phase == .restoringTerminalInput(id: restorationID))
    }

    @Test
    func cancellationInvalidatesPendingTerminalInputRestoration() {
        var lifecycle = TerminalNativeSelectionLifecycle()
        let restorationID = UUID()

        lifecycle.prepare(restoreTerminalInput: true)
        lifecycle.beginInteraction(restoreTerminalInput: false)
        #expect(lifecycle.endInteraction(restorationID: restorationID) == restorationID)

        lifecycle.cancel()

        let didRestore = lifecycle.completeRestoration(id: restorationID)
        #expect(!didRestore)
        #expect(lifecycle.phase == .inactive)
    }
}
