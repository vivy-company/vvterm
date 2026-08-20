import Foundation
import Testing
@testable import VVTerm

struct ServerMoveSupportEdgeCaseTests {
    private func makeWorkspace(
        id: UUID = UUID(),
        name: String,
        order: Int,
        environments: [ServerEnvironment] = ServerEnvironment.builtInEnvironments
    ) -> Workspace {
        Workspace(
            id: id,
            name: name,
            order: order,
            environments: environments
        )
    }

    @Test
    func lockedSourceCanMoveIntoUnlockedWorkspaceOnFreePlan() {
        let unlocked = makeWorkspace(name: "Primary", order: 0)
        let locked = makeWorkspace(name: "Archive", order: 1)

        let allowedDestinations = ServerMoveSupport.allowedDestinationIDs(
            isPro: false,
            sourceWorkspaceId: locked.id,
            workspacesInOrder: [unlocked, locked],
            unlockedWorkspaceIds: Set([unlocked.id])
        )

        #expect(allowedDestinations == Set([unlocked.id]))
    }

    @Test
    func freePlanDoesNotOfferLockedWorkspaceAsDestination() {
        let unlockedA = makeWorkspace(name: "Primary", order: 0)
        let locked = makeWorkspace(name: "Archive", order: 1)
        let unlockedB = makeWorkspace(name: "Shared", order: 2)

        let allowedDestinations = ServerMoveSupport.allowedDestinationIDs(
            isPro: false,
            sourceWorkspaceId: unlockedA.id,
            workspacesInOrder: [unlockedA, locked, unlockedB],
            unlockedWorkspaceIds: Set([unlockedA.id, unlockedB.id])
        )

        #expect(allowedDestinations == Set([unlockedB.id]))
    }

    @Test
    func resolveEnvironmentKeepsPreferredEnvironmentWhenDestinationContainsIt() {
        let custom = ServerEnvironment(
            id: UUID(),
            name: "Preview",
            shortName: "Prev",
            colorHex: "#FF00AA"
        )
        let destination = makeWorkspace(
            name: "Destination",
            order: 0,
            environments: ServerEnvironment.builtInEnvironments + [custom]
        )

        let resolved = ServerMoveSupport.resolveEnvironment(
            currentEnvironment: .production,
            preferredEnvironment: custom,
            destination: destination
        )

        #expect(resolved.id == custom.id)
    }

    @Test
    func resolveEnvironmentFallsBackToProductionWhenCustomEnvironmentIsMissing() {
        let custom = ServerEnvironment(
            id: UUID(),
            name: "QA Blue",
            shortName: "QAB",
            colorHex: "#3366FF"
        )
        let destination = makeWorkspace(name: "Destination", order: 0)

        let resolved = ServerMoveSupport.resolveEnvironment(
            currentEnvironment: custom,
            destination: destination
        )

        #expect(resolved.id == ServerEnvironment.production.id)
    }
}
