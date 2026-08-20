import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalPresentationStateStoreTests {
    @Test
    func splitZoomIsEphemeralAndClearsWithItsTab() {
        let store = TerminalPresentationStateStore()
        let tabId = UUID()

        store.toggleSplitZoom(for: tabId)
        #expect(store.splitZoomedTabIds == [tabId])

        store.toggleSplitZoom(for: tabId)
        #expect(store.splitZoomedTabIds.isEmpty)

        store.toggleSplitZoom(for: tabId)
        store.removeTab(tabId)
        #expect(store.splitZoomedTabIds.isEmpty)
    }

    @Test
    func resetClearsTemporaryPresentationState() {
        let store = TerminalPresentationStateStore()
        store.toggleSplitZoom(for: UUID())
        #if os(iOS)
        let paneId = UUID()
        store.setTerminalFindNavigatorVisible(true, for: paneId)
        store.applyVoiceEvent(.recordingStarted, for: paneId)
        #endif

        store.reset()

        #expect(store.splitZoomedTabIds.isEmpty)
        #if os(iOS)
        #expect(store.terminalFindNavigatorVisibleByPane.isEmpty)
        #expect(store.terminalVoicePresentationByPane.isEmpty)
        #endif
    }

    #if os(iOS)
    @Test
    func paneCleanupRemovesFindAndVoicePresentationState() {
        let store = TerminalPresentationStateStore()
        let paneId = UUID()

        store.setTerminalFindNavigatorVisible(true, for: paneId)
        store.applyVoiceEvent(.recordingStarted, for: paneId)
        #expect(store.terminalFindNavigatorVisibleByPane[paneId] == true)
        #expect(store.voicePresentation(for: paneId) == .recording)

        store.removePane(paneId)
        #expect(store.terminalFindNavigatorVisibleByPane[paneId] == nil)
        #expect(store.terminalVoicePresentationByPane[paneId] == nil)
        #expect(store.voicePresentation(for: paneId) == .idle)
    }

    @Test
    func idleVoicePresentationIsNotStored() {
        let store = TerminalPresentationStateStore()
        let paneId = UUID()

        store.applyVoiceEvent(.recordingStarted, for: paneId)
        store.applyVoiceEvent(.recordingStopped, for: paneId)

        #expect(store.terminalVoicePresentationByPane[paneId] == nil)
        #expect(store.voicePresentation(for: paneId) == .idle)
    }
    #endif
}
