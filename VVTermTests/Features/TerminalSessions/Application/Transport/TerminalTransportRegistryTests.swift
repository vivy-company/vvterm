import Foundation
import Testing
@testable import VVTerm

private actor TerminalTransportTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if continuations.count >= count { return true }
            await Task.yield()
        }
        return continuations.count >= count
    }

    func resume(at index: Int) {
        continuations[index].resume()
    }
}

private final class TerminalTransportTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

@MainActor
private final class TerminalTransportTestRuntime {}

@Suite(.serialized)
@MainActor
struct TerminalTransportRegistryTests {
    @Test
    func registriesKeepShellRuntimeAndTaskOwnershipIndependent() async {
        let first = TerminalTransportRegistry<TerminalTransportTestRuntime>(
            staleShellStartThreshold: 120
        )
        let second = TerminalTransportRegistry<TerminalTransportTestRuntime>(
            staleShellStartThreshold: 120
        )
        let shellPaneId = UUID()
        let runtimePaneId = UUID()
        let taskPaneId = UUID()
        let serverId = UUID()
        let client = SSHClient.testing()
        let shellId = UUID()

        let start = first.beginShellStart(
            for: shellPaneId,
            serverId: serverId,
            client: client
        )
        guard let startToken = start.token else {
            Issue.record("Expected shell start ownership")
            return
        }
        #expect(first.registerShell(
            client: client,
            shellId: shellId,
            startToken: startToken,
            for: shellPaneId,
            serverId: serverId
        ) == .accepted)

        let runtime = first.runtime(for: runtimePaneId) {
            TerminalTransportTestRuntime()
        }
        let taskGate = TerminalTransportTestGate()
        let taskId = first.startConnectionTask(for: taskPaneId) { _ in
            await taskGate.wait()
        }
        guard let taskId else {
            Issue.record("Expected connection task ownership")
            return
        }
        #expect(await taskGate.waitForCount(1))

        #expect(first.shellRoute(for: shellPaneId)?.shellId == shellId)
        #expect(first.runtime(for: runtimePaneId) === runtime)
        #expect(first.isCurrentConnectionTask(taskId: taskId, for: taskPaneId))
        #expect(second.shellRoute(for: shellPaneId) == nil)
        #expect(second.runtime(for: runtimePaneId) == nil)
        #expect(!second.isCurrentConnectionTask(taskId: taskId, for: taskPaneId))
        #expect(second.ownedPaneIds.isEmpty)

        #expect(first.cancelConnectionTask(for: taskPaneId))
        await taskGate.resume(at: 0)
    }

    @Test
    func staleShellAndRuntimeCallbacksCannotRemoveReplacements() {
        let registry = TerminalTransportRegistry<TerminalTransportTestRuntime>(
            staleShellStartThreshold: 120
        )
        let paneId = UUID()
        let serverId = UUID()
        let client = SSHClient.testing()
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        let firstStart = registry.beginShellStart(
            for: paneId,
            serverId: serverId,
            client: client,
            now: startedAt
        )
        let replacementStart = registry.beginShellStart(
            for: paneId,
            serverId: serverId,
            client: client,
            now: startedAt.addingTimeInterval(120)
        )
        guard let firstToken = firstStart.token,
              let replacementToken = replacementStart.token else {
            Issue.record("Expected unique shell start ownership")
            return
        }

        registry.finishShellStart(
            for: paneId,
            client: client,
            startToken: firstToken
        )
        #expect(registry.registerShell(
            client: client,
            shellId: UUID(),
            startToken: firstToken,
            for: paneId,
            serverId: serverId
        ) == .stale)

        let replacementShellId = UUID()
        #expect(registry.registerShell(
            client: client,
            shellId: replacementShellId,
            startToken: replacementToken,
            for: paneId,
            serverId: serverId
        ) == .accepted)
        #expect(registry.shellRoute(for: paneId)?.shellId == replacementShellId)

        let runtimePaneId = UUID()
        let firstRuntime = registry.runtime(for: runtimePaneId) {
            TerminalTransportTestRuntime()
        }
        #expect(registry.detachRuntime(firstRuntime, for: runtimePaneId))
        let replacementRuntime = registry.runtime(for: runtimePaneId) {
            TerminalTransportTestRuntime()
        }
        #expect(!registry.detachRuntime(firstRuntime, for: runtimePaneId))
        #expect(registry.runtime(for: runtimePaneId) === replacementRuntime)
    }

    @Test
    func staleTaskCompletionCannotClearReplacementTask() async {
        let registry = TerminalTransportRegistry<TerminalTransportTestRuntime>(
            staleShellStartThreshold: 120
        )
        let paneId = UUID()
        let gate = TerminalTransportTestGate()

        let firstTaskId = registry.startConnectionTask(for: paneId) { _ in
            await gate.wait()
        }
        guard let firstTaskId else {
            Issue.record("Expected first connection task")
            return
        }
        #expect(await gate.waitForCount(1))
        #expect(registry.cancelConnectionTask(for: paneId))

        let replacementTaskId = registry.startConnectionTask(for: paneId) { _ in
            await gate.wait()
        }
        guard let replacementTaskId else {
            Issue.record("Expected replacement connection task")
            return
        }
        #expect(firstTaskId != replacementTaskId)
        #expect(await gate.waitForCount(2))

        await gate.resume(at: 0)
        for _ in 0..<20 { await Task.yield() }
        #expect(registry.isCurrentConnectionTask(
            taskId: replacementTaskId,
            for: paneId
        ))

        #expect(registry.cancelConnectionTask(for: paneId))
        await gate.resume(at: 1)
    }

    @Test
    func drainCancelsOwnedWorkAndReturnsEachTransportIdentityOnce() async {
        let registry = TerminalTransportRegistry<TerminalTransportTestRuntime>(
            staleShellStartThreshold: 120
        )
        let registeredPaneId = UUID()
        let pendingPaneId = UUID()
        let taskPaneId = UUID()
        let serverId = UUID()
        let sharedClient = SSHClient.testing()
        let sharedRuntime = TerminalTransportTestRuntime()

        let start = registry.beginShellStart(
            for: registeredPaneId,
            serverId: serverId,
            client: sharedClient
        )
        guard let startToken = start.token else {
            Issue.record("Expected registered shell start")
            return
        }
        #expect(registry.registerShell(
            client: sharedClient,
            shellId: UUID(),
            startToken: startToken,
            for: registeredPaneId,
            serverId: serverId
        ) == .accepted)
        _ = registry.beginShellStart(
            for: pendingPaneId,
            serverId: serverId,
            client: sharedClient
        )
        _ = registry.runtime(for: registeredPaneId) { sharedRuntime }
        _ = registry.runtime(for: pendingPaneId) { sharedRuntime }

        let taskGate = TerminalTransportTestGate()
        let cleanupGate = TerminalTransportTestGate()
        let taskCancellations = TerminalTransportTestCounter()
        let cleanupStarts = TerminalTransportTestCounter()
        let cleanupCancellations = TerminalTransportTestCounter()
        let cleanupCompletions = TerminalTransportTestCounter()
        #expect(registry.startConnectionTask(for: taskPaneId) { _ in
            await withTaskCancellationHandler {
                await taskGate.wait()
            } onCancel: {
                taskCancellations.increment()
            }
        } != nil)
        let cleanupTask = Task { @MainActor in
            await registry.performTrackedCleanup(for: sharedClient) {
                cleanupStarts.increment()
                await withTaskCancellationHandler {
                    await cleanupGate.wait()
                } onCancel: {
                    cleanupCancellations.increment()
                }
                cleanupCompletions.increment()
            }
        }
        #expect(await taskGate.waitForCount(1))
        #expect(await cleanupGate.waitForCount(1))
        #expect(registry.ownedPaneIds.contains(taskPaneId))

        let drained = registry.drain()
        for _ in 0..<2_000 where taskCancellations.value == 0
            || cleanupCancellations.value == 0 {
            await Task.yield()
        }
        #expect(taskCancellations.value == 1)
        #expect(cleanupCancellations.value == 1)
        #expect(cleanupCompletions.value == 0)
        #expect(drained.clients.count == 1)
        #expect(drained.clients.first === sharedClient)
        #expect(drained.runtimes.count == 1)
        #expect(drained.runtimes.first === sharedRuntime)
        #expect(registry.ownedPaneIds.isEmpty)
        #expect(registry.shellRoute(for: registeredPaneId) == nil)
        #expect(registry.runtime(for: registeredPaneId) == nil)
        let repeatedDrain = registry.drain()
        #expect(repeatedDrain.clients.isEmpty)
        #expect(repeatedDrain.runtimes.isEmpty)

        await taskGate.resume(at: 0)
        await cleanupGate.resume(at: 0)
        await cleanupTask.value
        #expect(cleanupStarts.value == 1)
        #expect(cleanupCompletions.value == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(cleanupCompletions.value == 1)
    }
}
