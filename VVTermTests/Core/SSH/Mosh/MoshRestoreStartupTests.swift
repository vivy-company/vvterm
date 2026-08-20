import Testing
@testable import VVTerm

struct MoshRestoreStartupTests {
    @Test
    func staleRestoreStopsBeforeResize() async {
        let current = MoshRestoreCurrentState()
        let startGate = MoshRestoreTestGate()
        let events = MoshRestoreEventRecorder()

        let restore = Task {
            try await MoshRestoreStartup.run(
                restore: { 1 },
                start: { session in
                    await events.recordStart(session)
                    await startGate.wait()
                },
                resize: { session in
                    await events.recordResize(session)
                },
                isCurrent: {
                    await current.value
                },
                stop: { session in
                    await events.recordStop(session)
                }
            )
        }

        await startGate.waitUntilEntered()
        await current.invalidate()
        await startGate.open()

        await #expect(throws: CancellationError.self) {
            try await restore.value
        }
        #expect(await events.starts == [1])
        #expect(await events.resizes.isEmpty)
        #expect(await events.stops == [1])
    }

    @Test
    func currentRestoreStartsAndResizesWithoutStopping() async throws {
        let events = MoshRestoreEventRecorder()

        let restored = try await MoshRestoreStartup.run(
            restore: { 7 },
            start: { session in
                await events.recordStart(session)
            },
            resize: { session in
                await events.recordResize(session)
            },
            isCurrent: { true },
            stop: { session in
                await events.recordStop(session)
            }
        )

        #expect(restored == 7)
        #expect(await events.starts == [7])
        #expect(await events.resizes == [7])
        #expect(await events.stops.isEmpty)
    }
}

private actor MoshRestoreCurrentState {
    private(set) var value = true

    func invalidate() {
        value = false
    }
}

private actor MoshRestoreTestGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            openContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        openContinuation?.resume()
        openContinuation = nil
    }
}

private actor MoshRestoreEventRecorder {
    private(set) var starts: [Int] = []
    private(set) var resizes: [Int] = []
    private(set) var stops: [Int] = []

    func recordStart(_ session: Int) {
        starts.append(session)
    }

    func recordResize(_ session: Int) {
        resizes.append(session)
    }

    func recordStop(_ session: Int) {
        stops.append(session)
    }
}
