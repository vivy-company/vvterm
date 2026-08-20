import Darwin
import Foundation
import Testing
@testable import VVTerm

struct SSHAddressConnectorIntegrationTests {
    @Test
    func unreachableFirstAddressDoesNotBlockReachableFallback() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let unreachableHost = ProcessInfo.processInfo.environment["VVTERM_UNREACHABLE_TEST_HOST"]
            ?? "192.168.101.253"
        let unreachable = try SSHAddressConnector.resolvedCandidates(
            host: unreachableHost,
            port: listener.port
        )
        let reachable = try SSHAddressConnector.resolvedCandidates(
            host: "127.0.0.1",
            port: listener.port
        )
        let startedAt = ContinuousClock.now

        let descriptor = try await SSHAddressConnector.connect(
            candidates: unreachable + reachable,
            trace: nil,
            timeout: .seconds(2)
        )
        Darwin.close(descriptor)

        #expect(startedAt.duration(to: .now) < .seconds(1))
    }

    @Test
    func addressConnectionStopsPromptlyWhenCancelled() async throws {
        let unreachableHost = ProcessInfo.processInfo.environment["VVTERM_UNREACHABLE_TEST_HOST"]
            ?? "192.168.101.253"
        let resolvedCandidates = try SSHAddressConnector.resolvedCandidates(
            host: unreachableHost,
            port: 65_000
        )
        var gateContinuation: AsyncStream<Void>.Continuation?
        let gate = AsyncStream<Void> { gateContinuation = $0 }
        let task = Task {
            for await _ in gate { break }
            return try await SSHAddressConnector.connect(
                candidates: resolvedCandidates,
                trace: nil,
                timeout: .seconds(5)
            )
        }
        let cancellationStartedAt = ContinuousClock.now
        task.cancel()
        gateContinuation?.finish()

        do {
            let descriptor = try await task.value
            Darwin.close(descriptor)
            Issue.record("Unreachable candidate unexpectedly connected")
        } catch is CancellationError {
            #expect(cancellationStartedAt.duration(to: .now) < .seconds(1))
        } catch {
            Issue.record("Expected cancellation, received: \(error)")
        }
    }
}
