import Testing
@testable import VVTerm

@MainActor
struct TerminalKeyboardSyncSchedulerTests {
    @Test
    func coalescesScheduledRequestsIntoLatestReason() {
        var scheduler = TerminalKeyboardSyncScheduler()

        let didScheduleFirst = scheduler.request(reason: "activePane")
        let didScheduleSecond = scheduler.request(reason: "viewActive")

        #expect(didScheduleFirst)
        #expect(!didScheduleSecond)
        #expect(scheduler.phase == .scheduled(reason: "viewActive"))
        let reason = scheduler.beginSync()
        #expect(reason == "viewActive")
    }

    @Test
    func schedulesOneFollowUpForRequestsDuringSync() {
        var scheduler = TerminalKeyboardSyncScheduler()
        let didSchedule = scheduler.request(reason: "activePane")
        let activeReason = scheduler.beginSync()

        let scheduledWhileSyncing = scheduler.request(reason: "keyboardShown")
        let scheduledAgainWhileSyncing = scheduler.request(reason: "keyboardHidden")
        let didScheduleFollowUp = scheduler.finishSync()

        #expect(didSchedule)
        #expect(activeReason == "activePane")
        #expect(!scheduledWhileSyncing)
        #expect(!scheduledAgainWhileSyncing)
        #expect(didScheduleFollowUp)
        #expect(scheduler.phase == .scheduled(reason: "coalescedResync"))
    }

    @Test
    func becomesIdleWhenSyncHasNoPendingRequest() {
        var scheduler = TerminalKeyboardSyncScheduler()
        let didSchedule = scheduler.request(reason: "userShow")
        let activeReason = scheduler.beginSync()
        let didScheduleFollowUp = scheduler.finishSync()

        #expect(didSchedule)
        #expect(activeReason == "userShow")
        #expect(!didScheduleFollowUp)
        #expect(scheduler.phase == .idle(lastReason: "userShow"))
    }

    @Test
    func cancellationMakesQueuedSyncStale() {
        var scheduler = TerminalKeyboardSyncScheduler()
        let didSchedule = scheduler.request(reason: "activePane")

        scheduler.cancel(reason: "routeNavigation")
        let reason = scheduler.beginSync()

        #expect(didSchedule)
        #expect(reason == nil)
        #expect(scheduler.phase == .idle(lastReason: "routeNavigation"))
    }
}
