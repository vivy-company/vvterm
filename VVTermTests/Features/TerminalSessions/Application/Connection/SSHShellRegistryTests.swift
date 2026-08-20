import Foundation
import Testing
@testable import VVTerm

struct SSHShellRegistryTests {
    @Test
    func shellStartExpiresAtStaleThreshold() {
        let paneId = UUID()
        let serverId = UUID()
        let client = SSHClient.testing()
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var registry = SSHShellRegistry(staleThreshold: 120)

        #expect(registry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client,
            now: startedAt
        ).started)

        let beforeThreshold = registry.isStartInFlight(
            for: paneId,
            now: startedAt.addingTimeInterval(119.999)
        )
        #expect(beforeThreshold.inFlight)
        #expect(beforeThreshold.staleContext == nil)

        let atThreshold = registry.isStartInFlight(
            for: paneId,
            now: startedAt.addingTimeInterval(120)
        )
        #expect(!atThreshold.inFlight)
        #expect(atThreshold.staleContext?.client === client)
        #expect(registry.connectionStartToken(for: paneId) == nil)
    }

    @Test
    func connectionStartTokenIncludesPendingShellStart() {
        let paneId = UUID()
        let client = SSHClient.testing()
        var registry = SSHShellRegistry(staleThreshold: 120)

        let start = registry.tryBeginStart(
            for: paneId,
            serverId: UUID(),
            client: client
        )
        #expect(start.started)
        #expect(registry.client(for: paneId) == nil)
        #expect(registry.connectionClient(for: paneId) === client)
        #expect(registry.connectionStartToken(for: paneId) == start.token)
    }

    @Test
    func anotherPendingStartProtectsSharedClientFromAbort() {
        let reconnectingPaneId = UUID()
        let pendingPaneId = UUID()
        let client = SSHClient.testing()
        var registry = SSHShellRegistry(staleThreshold: 120)

        _ = registry.tryBeginStart(
            for: reconnectingPaneId,
            serverId: UUID(),
            client: client
        )
        _ = registry.tryBeginStart(
            for: pendingPaneId,
            serverId: UUID(),
            client: client
        )

        #expect(
            registry.hasOtherClientReferences(
                using: client,
                excluding: reconnectingPaneId
            )
        )
        #expect(
            registry.hasOtherClientReferences(
                using: client,
                excluding: pendingPaneId
            )
        )
    }

    @Test
    func staleFinishCannotRemoveReplacementStartUsingSameClient() {
        let paneId = UUID()
        let serverId = UUID()
        let client = SSHClient.testing()
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var registry = SSHShellRegistry(staleThreshold: 120)

        let firstStart = registry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client,
            now: startedAt
        )
        let replacementStart = registry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client,
            now: startedAt.addingTimeInterval(120)
        )
        let shellId = UUID()

        #expect(firstStart.started)
        #expect(replacementStart.started)
        #expect(firstStart.token != replacementStart.token)
        guard let firstToken = firstStart.token,
              let replacementToken = replacementStart.token else {
            Issue.record("Expected unique start tokens")
            return
        }

        registry.finishStart(
            for: paneId,
            client: client,
            startToken: firstToken
        )
        let staleRegistration = registry.register(
            client: client,
            shellId: UUID(),
            startToken: firstToken,
            for: paneId,
            serverId: serverId
        )
        let replacementRegistration = registry.register(
            client: client,
            shellId: shellId,
            startToken: replacementToken,
            for: paneId,
            serverId: serverId
        )

        #expect(staleRegistration == .stale)
        #expect(replacementRegistration == .accepted)
        #expect(registry.connectionClient(for: paneId) === client)
        #expect(registry.owns(client: client, shellId: shellId, for: paneId))
    }

    @Test
    func drainingBackgroundShellsDoesNotOwnReplacementStart() {
        let paneId = UUID()
        let serverId = UUID()
        let oldClient = SSHClient.testing()
        let replacementClient = SSHClient.testing()
        var registry = SSHShellRegistry(staleThreshold: 120)

        let oldStart = registry.tryBeginStart(for: paneId, serverId: serverId, client: oldClient)
        guard let oldStartToken = oldStart.token else {
            Issue.record("Expected the original start to begin")
            return
        }
        _ = registry.register(
            client: oldClient,
            shellId: UUID(),
            startToken: oldStartToken,
            for: paneId,
            serverId: serverId
        )

        let detached = registry.drain()
        let replacement = registry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: replacementClient
        )
        let staleRegistration = registry.register(
            client: oldClient,
            shellId: UUID(),
            startToken: oldStartToken,
            for: paneId,
            serverId: serverId
        )

        #expect(detached.registrations.count == 1)
        #expect(detached.pendingStarts.isEmpty)
        #expect(staleRegistration == .stale)
        #expect(replacement.started)
        #expect(registry.connectionStartToken(for: paneId) == replacement.token)
    }
}
