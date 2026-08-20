import Combine
import Foundation

/// Owns temporary terminal presentation choices and observed presentation facts.
/// This state is local to the current process and is not persisted.
@MainActor
final class TerminalPresentationStateStore: ObservableObject {
    @Published private(set) var splitZoomedTabIds: Set<UUID> = []

    #if os(iOS)
    @Published private(set) var terminalFindNavigatorVisibleByPane: [UUID: Bool] = [:]
    @Published private(set) var terminalVoicePresentationByPane: [UUID: TerminalVoicePresentationState] = [:]
    #endif

    func toggleSplitZoom(for tabId: UUID) {
        if splitZoomedTabIds.contains(tabId) {
            splitZoomedTabIds.remove(tabId)
        } else {
            splitZoomedTabIds.insert(tabId)
        }
    }

    func removeTab(_ tabId: UUID) {
        splitZoomedTabIds.remove(tabId)
    }

    #if os(iOS)
    func setTerminalFindNavigatorVisible(_ isVisible: Bool, for paneId: UUID) {
        guard terminalFindNavigatorVisibleByPane[paneId] != isVisible else { return }
        terminalFindNavigatorVisibleByPane[paneId] = isVisible
    }

    func voicePresentation(for paneId: UUID) -> TerminalVoicePresentationState {
        terminalVoicePresentationByPane[paneId] ?? .idle
    }

    func applyVoiceEvent(
        _ event: TerminalVoicePresentationState.Event,
        for paneId: UUID
    ) {
        let current = voicePresentation(for: paneId)
        let next = current.applying(event)
        guard next != current else { return }

        if next == .idle {
            terminalVoicePresentationByPane.removeValue(forKey: paneId)
        } else {
            terminalVoicePresentationByPane[paneId] = next
        }
    }

    func removePane(_ paneId: UUID) {
        terminalFindNavigatorVisibleByPane.removeValue(forKey: paneId)
        terminalVoicePresentationByPane.removeValue(forKey: paneId)
    }
    #endif

    #if DEBUG
    func reset() {
        splitZoomedTabIds.removeAll()
        #if os(iOS)
        terminalFindNavigatorVisibleByPane.removeAll()
        terminalVoicePresentationByPane.removeAll()
        #endif
    }
    #endif
}
