import Combine
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TeleportConnectionSignInCoordinatorTests {
    private nonisolated static let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func ordinarySSHDoesNotReadTeleportAccess() async {
        let server = Server(workspaceId: UUID(), name: "SSH", host: "example.test", username: "deploy")
        let coordinator = TeleportConnectionSignInCoordinator(
            summary: { _ in Issue.record("SSH must not read Teleport access"); return nil },
            currentServer: { _ in nil }, now: { Self.date }
        )
        #expect(await coordinator.ensureAccess(for: server))
        #expect(coordinator.request == nil)
    }

    @Test
    func usableAccessDoesNotPresentSignIn() async throws {
        let server = try makeServer()
        let source = SummarySource(value: makeSummary())
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(source: source, current: current)

        #expect(await coordinator.ensureAccess(for: server))
        #expect(coordinator.request == nil)
        #expect(await source.readCount == 1)
    }

    @Test(arguments: InvalidAccess.allCases)
    func unusableOrUnreadableAccessRequestsSignIn(reason: InvalidAccess) async throws {
        let server = try makeServer()
        let source = SummarySource(value: summary(for: reason), fails: reason == .readFailure)
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(source: source, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }

        let request = await waitForRequest(coordinator)
        #expect(request.server == server)
        coordinator.cancel(request.id)
        #expect(await attempt.value == false)
        #expect(coordinator.request == nil)
    }

    @Test
    func completionChecksStoredAccessAndKeepsAnInvalidAttemptOpen() async throws {
        let server = try makeServer()
        let source = SummarySource(value: nil)
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(source: source, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        let request = await waitForRequest(coordinator)

        await source.set(makeSummary(account: "another-account"))
        #expect(await coordinator.complete(request.id) == false)
        #expect(coordinator.request?.id == request.id)
        await source.set(makeSummary())
        #expect(await coordinator.complete(request.id))
        #expect(await attempt.value)
        #expect(coordinator.request == nil)
        #expect(await coordinator.complete(request.id) == false)
    }

    @Test
    func anotherAttemptCannotReplaceCheckingOrWaitingAccess() async throws {
        let server = try makeServer()
        let gate = SummaryGate()
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(gate: gate, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        await gate.waitForRead()

        #expect(await coordinator.ensureAccess(for: server) == false)
        await gate.resolve(nil)
        let request = await waitForRequest(coordinator)
        #expect(await coordinator.ensureAccess(for: server) == false)
        #expect(coordinator.request?.id == request.id)
        coordinator.cancel()
        #expect(await attempt.value == false)
    }

    @Test
    func aPreCancelledAttemptDoesNotReadOrPresentAccess() async throws {
        let server = try makeServer()
        let source = SummarySource(value: nil)
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(source: source, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        attempt.cancel()

        #expect(await attempt.value == false)
        #expect(await source.readCount == 0)
        #expect(coordinator.request == nil)
    }

    @Test(arguments: [false, true])
    func cancellationWhileReadingResumesWithoutWaitingForTheRead(teardown: Bool) async throws {
        let server = try makeServer()
        let gate = SummaryGate()
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(gate: gate, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        await gate.waitForRead()

        if teardown { coordinator.cancel() } else { attempt.cancel() }
        // The read deliberately ignores cancellation until the test releases it.
        #expect(await attempt.value == false)
        #expect(coordinator.request == nil)
        await gate.resolve(makeSummary())
    }

    @Test(arguments: [false, true])
    func cancellationWhileWaitingClearsTheRequest(teardown: Bool) async throws {
        let server = try makeServer()
        let source = SummarySource(value: nil)
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(source: source, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        _ = await waitForRequest(coordinator)

        if teardown { coordinator.cancel() } else { attempt.cancel() }
        #expect(await attempt.value == false)
        #expect(coordinator.request == nil)
    }

    @Test
    func changedSavedServerIsRejectedBeforeReading() async throws {
        let server = try makeServer()
        let source = SummarySource(value: makeSummary())
        let current = CurrentServer(server)
        current.server?.notes = "Changed"
        let coordinator = makeCoordinator(source: source, current: current)

        #expect(await coordinator.ensureAccess(for: server) == false)
        #expect(await source.readCount == 0)
        #expect(coordinator.request == nil)
    }

    @Test
    func changedSavedServerIsRejectedAfterReading() async throws {
        let server = try makeServer()
        let gate = SummaryGate()
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(gate: gate, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        await gate.waitForRead()
        current.server?.notes = "Changed"
        await gate.resolve(makeSummary())

        #expect(await attempt.value == false)
        #expect(coordinator.request == nil)
    }

    @Test
    func connectionReportingBeforeCheckingDoesNotInvalidateAccess() async throws {
        let server = try makeServer()
        let source = SummarySource(value: makeSummary())
        let current = CurrentServer(server)
        current.updateConnectionReporting()
        let coordinator = makeCoordinator(source: source, current: current)

        #expect(await coordinator.ensureAccess(for: server))
        #expect(coordinator.request == nil)
        #expect(await source.readCount == 1)
    }

    @Test
    func connectionReportingBeforeCompletionDoesNotInvalidateTheRequest() async throws {
        let server = try makeServer()
        let source = SummarySource(value: nil)
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(source: source, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        let request = await waitForRequest(coordinator)
        current.updateConnectionReporting()
        await source.set(makeSummary())

        #expect(await coordinator.complete(request.id))
        #expect(await attempt.value)
        #expect(coordinator.request == nil)
    }

    @Test(arguments: [false, true])
    func connectionReportingDuringAReadDoesNotInvalidateAccess(completing: Bool) async throws {
        let server = try makeServer()
        let gate = SummaryGate()
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(gate: gate, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        await gate.waitForRead()
        var completion: Task<Bool, Never>?
        if completing {
            await gate.resolve(nil)
            let request = await waitForRequest(coordinator)
            completion = Task { await coordinator.complete(request.id) }
            await gate.waitForRead()
        }
        current.updateConnectionReporting()
        await gate.resolve(makeSummary())

        if let completion { #expect(await completion.value) }
        #expect(await attempt.value)
        #expect(coordinator.request == nil)
    }

    @Test(arguments: [false, true])
    func reportingUpdatesDoNotHideUserOrSecurityEdits(changesSecurity: Bool) async throws {
        let server = try makeServer()
        let source = SummarySource(value: makeSummary())
        let current = CurrentServer(server)
        current.updateConnectionReporting()
        if changesSecurity { current.server?.requiresBiometricUnlock = true }
        else { current.server?.notes = "Edited" }
        let coordinator = makeCoordinator(source: source, current: current)

        #expect(await coordinator.ensureAccess(for: server) == false)
        #expect(await source.readCount == 0)
        #expect(coordinator.request == nil)
    }

    @Test(arguments: [false, true])
    func completionRejectsAChangedOrDeletedSavedServer(deleted: Bool) async throws {
        let server = try makeServer()
        let source = SummarySource(value: nil)
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(source: source, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        let request = await waitForRequest(coordinator)
        if deleted { current.server = nil } else { current.server?.notes = "Changed" }

        #expect(await coordinator.complete(request.id) == false)
        #expect(await attempt.value == false)
        #expect(coordinator.request == nil)
        #expect(await source.readCount == 1)
    }

    @Test
    func completionRejectsAChangeDuringItsRead() async throws {
        let server = try makeServer()
        let gate = SummaryGate()
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(gate: gate, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        await gate.waitForRead()
        await gate.resolve(nil)
        let request = await waitForRequest(coordinator)
        let completion = Task { await coordinator.complete(request.id) }
        await gate.waitForRead()
        current.server?.notes = "Changed"
        await gate.resolve(makeSummary())

        #expect(await completion.value == false)
        #expect(await attempt.value == false)
        #expect(coordinator.request == nil)
    }

    @Test
    func staleCompletionCannotCompleteOrCancelANewerRequest() async throws {
        let server = try makeServer()
        let gate = SummaryGate()
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(gate: gate, current: current)
        let first = Task { await coordinator.ensureAccess(for: server) }
        await gate.waitForRead()
        await gate.resolve(nil)
        let oldRequest = await waitForRequest(coordinator)
        let oldCompletion = Task { await coordinator.complete(oldRequest.id) }
        await gate.waitForRead()
        coordinator.cancel(oldRequest.id)
        #expect(await first.value == false)

        let second = Task { await coordinator.ensureAccess(for: server) }
        await gate.resolve(makeSummary())
        #expect(await oldCompletion.value == false)
        await gate.waitForRead()
        await gate.resolve(nil)
        let newRequest = await waitForRequest(coordinator)
        #expect(newRequest.id != oldRequest.id)
        #expect(await coordinator.complete(oldRequest.id) == false)
        coordinator.cancel(oldRequest.id)
        #expect(coordinator.request?.id == newRequest.id)
        coordinator.cancel(newRequest.id)
        #expect(await second.value == false)
    }

    @Test
    func cancellingCompletionResumesThePendingCaller() async throws {
        let server = try makeServer()
        let gate = SummaryGate()
        let current = CurrentServer(server)
        let coordinator = makeCoordinator(gate: gate, current: current)
        let attempt = Task { await coordinator.ensureAccess(for: server) }
        await gate.waitForRead()
        await gate.resolve(nil)
        let request = await waitForRequest(coordinator)
        let completion = Task { await coordinator.complete(request.id) }
        await gate.waitForRead()
        completion.cancel()

        #expect(await attempt.value == false)
        #expect(coordinator.request == nil)
        await gate.resolve(makeSummary())
        #expect(await completion.value == false)
    }

    enum InvalidAccess: CaseIterable {
        case missing, readFailure, account, cluster, login, expired, expiryBoundary, invalidExpiry
    }

    private func summary(for reason: InvalidAccess) -> TeleportAccessSummary? {
        switch reason {
        case .missing, .readFailure: nil
        case .account: makeSummary(account: "another-account")
        case .cluster: makeSummary(cluster: "another-cluster")
        case .login: makeSummary(logins: ["another-login"])
        case .expired: makeSummary(expiry: Self.date.addingTimeInterval(-1))
        case .expiryBoundary: makeSummary(expiry: Self.date)
        case .invalidExpiry: makeSummary(expiry: Date(timeIntervalSince1970: .infinity))
        }
    }

    private func makeServer() throws -> Server {
        Server(
            workspaceId: UUID(), name: "Teleport", host: "node-id", username: "deploy",
            connectionMode: .teleport,
            teleportConfiguration: try TeleportServerConfiguration(
                profile: TeleportProfileConfiguration(proxyURL: "https://proxy.example.test", account: "alice"),
                clusterName: "root-cluster", nodeID: "node-id"
            )
        )
    }

    private func makeSummary(
        account: String = "alice", cluster: String = "root-cluster", logins: [String] = ["deploy"],
        expiry: Date = TeleportConnectionSignInCoordinatorTests.date.addingTimeInterval(3600)
    ) -> TeleportAccessSummary {
        TeleportAccessSummary(account: account, clusterName: cluster, validBefore: expiry, allowedLogins: logins)
    }

    private func makeCoordinator(source: SummarySource, current: CurrentServer) -> TeleportConnectionSignInCoordinator {
        TeleportConnectionSignInCoordinator(
            summary: { _ in try await source.read() }, currentServer: { _ in current.server }, now: { Self.date }
        )
    }

    private func makeCoordinator(gate: SummaryGate, current: CurrentServer) -> TeleportConnectionSignInCoordinator {
        TeleportConnectionSignInCoordinator(
            summary: { _ in try await gate.read() }, currentServer: { _ in current.server }, now: { Self.date }
        )
    }

    private func waitForRequest(
        _ coordinator: TeleportConnectionSignInCoordinator
    ) async -> TeleportConnectionSignInCoordinator.Request {
        if let request = coordinator.request { return request }
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = coordinator.objectWillChange.sink { continuation.yield(()) }
        defer {
            subscription.cancel()
            continuation.finish()
        }
        for await _ in changes {
            // Published changes are sent before their new value is assigned.
            await Task.yield()
            if let request = coordinator.request { return request }
        }
        preconditionFailure("The coordinator must publish a sign-in request")
    }

    @MainActor
    private final class CurrentServer {
        var server: Server?
        init(_ server: Server) { self.server = server }

        func updateConnectionReporting() {
            server?.lastConnected = Date(timeIntervalSince1970: 1_700_000_100)
            server?.detectedSystemIdentity = RemoteSystemIdentity(kind: .linux, displayName: "Linux")
            server?.updatedAt = Date(timeIntervalSince1970: 1_700_000_101)
        }
    }

    private actor SummarySource {
        private enum Failure: Error { case read }
        private var value: TeleportAccessSummary?
        private let fails: Bool
        private(set) var readCount = 0

        init(value: TeleportAccessSummary?, fails: Bool = false) {
            self.value = value
            self.fails = fails
        }

        func set(_ value: TeleportAccessSummary?) { self.value = value }

        func read() throws -> TeleportAccessSummary? {
            readCount += 1
            if fails { throw Failure.read }
            return value
        }
    }

    private actor SummaryGate {
        private var reads: [CheckedContinuation<TeleportAccessSummary?, any Error>] = []
        private var observers: [CheckedContinuation<Void, Never>] = []

        func read() async throws -> TeleportAccessSummary? {
            try await withCheckedThrowingContinuation { continuation in
                reads.append(continuation)
                let waiting = observers
                observers.removeAll()
                for observer in waiting { observer.resume() }
            }
        }

        func waitForRead() async {
            guard reads.isEmpty else { return }
            await withCheckedContinuation { observers.append($0) }
        }

        func resolve(_ summary: TeleportAccessSummary?) {
            precondition(!reads.isEmpty)
            reads.removeFirst().resume(returning: summary)
        }
    }
}
