import Foundation
import Combine
import Testing
@testable import VVTerm

extension TerminalTabManagerLifecycleTests {
    @Suite(.serialized)
    @MainActor
    struct Presentation: TerminalTabManagerTestSupport {
        @Test
        func toolbarProjectionSeparatesRouteTabTitleAndVoiceInvalidation() async {
            await withCleanManager { manager in
                let observedTab = TerminalTab(serverId: UUID(), title: "Observed")
                let otherTab = TerminalTab(serverId: UUID(), title: "Other")
                installTab(observedTab, in: manager, connectionState: .connected)
                installTab(otherTab, in: manager, connectionState: .connected)
                let projection = TerminalServerToolbarProjection(
                    serverId: observedTab.serverId,
                    tabManager: manager
                )
                var contentUpdates = 0
                var tabStripUpdates = 0
                #if os(iOS)
                var floatingControlUpdates = 0
                #endif
                var routeUpdates = 0
                var cancellations = [
                    projection.objectWillChange.sink { routeUpdates += 1 },
                    projection.content.objectWillChange.sink { contentUpdates += 1 },
                    projection.tabStrip.objectWillChange.sink { tabStripUpdates += 1 }
                ]
                #if os(iOS)
                cancellations.append(
                    projection.floatingControls.objectWillChange.sink { floatingControlUpdates += 1 }
                )
                #endif
                defer {
                    cancellations.forEach { $0.cancel() }
                }
    
                manager.updatePaneWorkingDirectory(
                    observedTab.rootPaneId,
                    rawDirectory: "/tmp/output-metadata"
                )
                #expect(contentUpdates == 0)
                #expect(tabStripUpdates == 0)
                #if os(iOS)
                #expect(floatingControlUpdates == 0)
                #endif
                #expect(routeUpdates == 0)
    
                manager.updatePaneTitle(observedTab.rootPaneId, rawTitle: "Output title")
                #expect(contentUpdates == 0)
                #expect(tabStripUpdates == 1)
                #expect(projection.tabStrip.state.items.first?.title == "Output title")
                #if os(iOS)
                #expect(floatingControlUpdates == 0)
                #endif
                #expect(routeUpdates == 0)
    
                manager.updatePaneTitle(observedTab.rootPaneId, rawTitle: "Output title")
                manager.updatePaneTitle(otherTab.rootPaneId, rawTitle: "Other output title")
                #expect(contentUpdates == 0)
                #expect(tabStripUpdates == 1)
                #if os(iOS)
                #expect(floatingControlUpdates == 0)
                #endif
                #expect(routeUpdates == 0)
    
                #if os(iOS)
                manager.presentationState.applyVoiceEvent(.recordingStarted, for: otherTab.rootPaneId)
                #expect(floatingControlUpdates == 0)
                #expect(routeUpdates == 0)
    
                manager.presentationState.applyVoiceEvent(.recordingStarted, for: observedTab.rootPaneId)
                #expect(floatingControlUpdates == 1)
                #expect(routeUpdates == 1)
                #expect(manager.presentationState.voicePresentation(for: observedTab.rootPaneId) == .recording)
    
                manager.presentationState.applyVoiceEvent(.transcriptionSent, for: observedTab.rootPaneId)
                #expect(floatingControlUpdates == 2)
                #expect(routeUpdates == 2)
                #expect(manager.presentationState.voicePresentation(for: observedTab.rootPaneId) == .pendingReturn)
                #endif
            }
        }
    
        @Test
        func connectionAttemptUpdatesOnlyTheTabStripProjection() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Connecting")
                installTab(tab, in: manager, connectionState: .connecting)
                let projection = TerminalServerToolbarProjection(
                    serverId: tab.serverId,
                    tabManager: manager
                )
                var routeUpdates = 0
                var contentUpdates = 0
                var tabStripUpdates = 0
                let cancellations = [
                    projection.objectWillChange.sink { routeUpdates += 1 },
                    projection.content.objectWillChange.sink { contentUpdates += 1 },
                    projection.tabStrip.objectWillChange.sink { tabStripUpdates += 1 }
                ]
                defer { cancellations.forEach { $0.cancel() } }
    
                manager.updatePaneState(tab.rootPaneId, connectionState: .reconnecting(attempt: 2))
    
                #expect(routeUpdates == 0)
                #expect(contentUpdates == 0)
                #expect(tabStripUpdates == 1)
            }
        }
    
    }
}
