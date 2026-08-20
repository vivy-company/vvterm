#if os(macOS)
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct MacShellCommandBridgeTests {
    @Test
    func commandStateIsIsolatedPerSceneBridge() {
        let first = MacShellCommandBridge()
        let second = MacShellCommandBridge()
        let firstServerId = UUID()
        let secondServerId = UUID()
        var firstActionCount = 0
        var secondActionCount = 0

        first.update(
            ownerId: "first",
            serverViewTabActions: nil,
            splitActions: TerminalSplitActions(
                perform: { _ in firstActionCount += 1 },
                isEnabled: { _ in true },
                isZoomed: { false }
            ),
            activeServerId: firstServerId,
            activePaneId: nil
        )
        second.update(
            ownerId: "second",
            serverViewTabActions: nil,
            splitActions: TerminalSplitActions(
                perform: { _ in secondActionCount += 1 },
                isEnabled: { _ in true },
                isZoomed: { false }
            ),
            activeServerId: secondServerId,
            activePaneId: nil
        )

        first.splitActions?.perform(.splitRight)
        #expect(first.snapshot.hasSplitActions)
        #expect(first.activeServerId == firstServerId)
        #expect(second.activeServerId == secondServerId)
        #expect(firstActionCount == 1)
        #expect(secondActionCount == 0)

        second.clear(ownerId: "second")

        first.splitActions?.perform(.splitDown)
        #expect(first.activeServerId == firstServerId)
        #expect(firstActionCount == 2)
        #expect(second.activeServerId == nil)
        #expect(second.splitActions == nil)
    }

    @Test
    func onlyTheCurrentOwnerCanClearAWindowBridge() {
        let bridge = MacShellCommandBridge()
        let serverId = UUID()

        bridge.update(
            ownerId: "current",
            serverViewTabActions: nil,
            splitActions: nil,
            activeServerId: serverId,
            activePaneId: nil
        )
        bridge.clear(ownerId: "stale")
        #expect(bridge.activeServerId == serverId)

        bridge.clear(ownerId: "current")
        #expect(bridge.activeServerId == nil)
    }

    @Test
    func localDiscoveryUsesTypedDispatcherState() {
        let bridge = MacShellCommandBridge()
        var openCount = 0

        bridge.setLocalDiscovery { openCount += 1 }
        #expect(bridge.snapshot.hasLocalDiscovery)
        bridge.openLocalDiscovery?()
        #expect(openCount == 1)

        bridge.setLocalDiscovery(nil)
        #expect(!bridge.snapshot.hasLocalDiscovery)
        #expect(bridge.openLocalDiscovery == nil)
    }
}
#endif
