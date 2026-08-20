#if os(iOS)
import Foundation
import Testing
@testable import VVTerm

struct ServerTerminalNavigationRouteTests {
    @Test
    func connectingRouteCarriesOneStableDestinationIdentity() {
        let server = makeServer()
        let attemptID = UUID()
        let route = ServerTerminalNavigationRoute.connecting(
            server: server,
            attemptID: attemptID
        )

        #expect(route.serverId == server.id)
        #expect(route.connectingServer == server)
        #expect(route.connectionAttemptID == attemptID)
        #expect(route.isConnecting)
    }

    @Test
    func successfulConnectionAdvancesMatchingRouteWithoutChangingIdentity() throws {
        let server = makeServer()
        let attemptID = UUID()
        let route = try #require(
            ServerTerminalNavigationRoute.connecting(
                server: server,
                attemptID: attemptID
            )
            .resolvingConnection(for: attemptID, as: .succeeded)
        )

        #expect(route == .active(serverId: server.id))
        #expect(route.serverId == server.id)
        #expect(!route.isConnecting)
    }

    @Test
    func failedConnectionDismissesMatchingRoute() {
        let server = makeServer()
        let attemptID = UUID()
        let route = ServerTerminalNavigationRoute.connecting(
            server: server,
            attemptID: attemptID
        )
        .resolvingConnection(for: attemptID, as: .failed)

        #expect(route == nil)
    }

    @Test
    func staleSameServerCompletionCannotReplaceNewerAttempt() {
        let server = makeServer()
        let staleAttemptID = UUID()
        let currentAttemptID = UUID()
        let route = ServerTerminalNavigationRoute.connecting(
            server: server,
            attemptID: currentAttemptID
        )

        #expect(
            route.resolvingConnection(for: staleAttemptID, as: .succeeded)
                == route
        )
        #expect(
            route.resolvingConnection(for: staleAttemptID, as: .failed)
                == route
        )
    }

    @Test
    func activeDestinationIgnoresLateConnectionFailure() {
        let server = makeServer()
        let route = ServerTerminalNavigationRoute.active(serverId: server.id)

        #expect(
            route.resolvingConnection(for: UUID(), as: .failed)
                == route
        )
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Navigation",
            host: "example.com",
            username: "vvterm"
        )
    }
}
#endif
