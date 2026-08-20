import Foundation
import Testing
@testable import VVTerm

struct LocalSSHDiscoveryRunOwnershipTests {
    @Test
    func canceledTimeoutProbeAndBonjourCallbacksCannotOwnOrStopAReplacement() {
        let oldRunID = UUID()
        let replacementRunID = UUID()
        var ownership = LocalSSHDiscoveryRunOwnership()

        ownership.start(runID: oldRunID)
        ownership.start(runID: replacementRunID)

        let oldRunStoppedReplacement = ownership.stop(runID: oldRunID)
        #expect(!ownership.owns(runID: oldRunID))
        #expect(!oldRunStoppedReplacement)
        #expect(ownership.owns(runID: replacementRunID))
    }

    @Test
    func currentRunCanStopOnlyOnce() {
        let runID = UUID()
        var ownership = LocalSSHDiscoveryRunOwnership()

        ownership.start(runID: runID)

        let firstStop = ownership.stop(runID: runID)
        let secondStop = ownership.stop(runID: runID)
        #expect(firstStop)
        #expect(!secondStop)
        #expect(ownership.activeRunID == nil)
    }
}
