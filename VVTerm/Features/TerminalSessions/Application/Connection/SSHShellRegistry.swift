import Foundation

nonisolated struct SSHShellRegistry {
    nonisolated struct StartToken: Hashable, Sendable {
        let id: UUID

        init(id: UUID = UUID()) {
            self.id = id
        }
    }

    nonisolated struct Registration: Sendable {
        let serverId: UUID
        let client: SSHClient
        let shellId: UUID
        let startToken: StartToken
    }

    nonisolated struct StartContext: Sendable {
        let token: StartToken
        let startedAt: Date
        let client: SSHClient
        let serverId: UUID
    }

    nonisolated enum RegisterResult: Sendable, Equatable {
        case accepted
        case stale
    }

    nonisolated struct StartResult: Sendable {
        let token: StartToken?
        let staleContext: StartContext?

        var started: Bool { token != nil }
    }

    nonisolated struct InFlightResult: Sendable {
        let inFlight: Bool
        let staleContext: StartContext?
    }

    nonisolated struct DrainResult: Sendable {
        let registrations: [Registration]
        let pendingStarts: [StartContext]
    }

    private(set) var registrations: [UUID: Registration] = [:]
    private(set) var startsInFlight: [UUID: StartContext] = [:]
    private let staleThreshold: TimeInterval

    init(staleThreshold: TimeInterval) {
        self.staleThreshold = staleThreshold
    }

    mutating func register(
        client: SSHClient,
        shellId: UUID,
        startToken: StartToken,
        for entityId: UUID,
        serverId: UUID
    ) -> RegisterResult {
        guard let context = startsInFlight[entityId],
              ObjectIdentifier(context.client) == ObjectIdentifier(client),
              context.token == startToken,
              context.serverId == serverId,
              registrations[entityId] == nil else {
            return .stale
        }

        startsInFlight.removeValue(forKey: entityId)
        let newRegistration = Registration(
            serverId: serverId,
            client: client,
            shellId: shellId,
            startToken: startToken
        )
        registrations[entityId] = newRegistration
        return .accepted
    }

    mutating func unregister(for entityId: UUID) -> (registration: Registration?, pendingStart: StartContext?) {
        let pendingStart = startsInFlight.removeValue(forKey: entityId)
        let registration = registrations.removeValue(forKey: entityId)
        return (registration, pendingStart)
    }

    mutating func tryBeginStart(
        for entityId: UUID,
        serverId: UUID,
        client: SSHClient,
        now: Date = Date()
    ) -> StartResult {
        if registrations[entityId] != nil {
            return StartResult(token: nil, staleContext: nil)
        }

        if let context = startsInFlight[entityId] {
            if now.timeIntervalSince(context.startedAt) < staleThreshold {
                return StartResult(token: nil, staleContext: nil)
            }
            startsInFlight.removeValue(forKey: entityId)
            let replacement = StartContext(
                token: StartToken(),
                startedAt: now,
                client: client,
                serverId: serverId
            )
            startsInFlight[entityId] = replacement
            return StartResult(token: replacement.token, staleContext: context)
        }

        let context = StartContext(
            token: StartToken(),
            startedAt: now,
            client: client,
            serverId: serverId
        )
        startsInFlight[entityId] = context
        return StartResult(token: context.token, staleContext: nil)
    }

    mutating func finishStart(
        for entityId: UUID,
        client: SSHClient,
        startToken: StartToken
    ) {
        guard let context = startsInFlight[entityId] else { return }
        guard ObjectIdentifier(context.client) == ObjectIdentifier(client) else { return }
        guard context.token == startToken else { return }
        startsInFlight.removeValue(forKey: entityId)
    }

    mutating func isStartInFlight(for entityId: UUID, now: Date = Date()) -> InFlightResult {
        guard let context = startsInFlight[entityId] else {
            return InFlightResult(inFlight: false, staleContext: nil)
        }

        if now.timeIntervalSince(context.startedAt) >= staleThreshold {
            startsInFlight.removeValue(forKey: entityId)
            return InFlightResult(inFlight: false, staleContext: context)
        }

        return InFlightResult(inFlight: true, staleContext: nil)
    }

    func registration(for entityId: UUID) -> Registration? {
        registrations[entityId]
    }

    func shellId(for entityId: UUID) -> UUID? {
        registrations[entityId]?.shellId
    }

    func owns(client: SSHClient, shellId: UUID, for entityId: UUID) -> Bool {
        guard let registration = registrations[entityId] else { return false }
        return ObjectIdentifier(registration.client) == ObjectIdentifier(client)
            && registration.shellId == shellId
    }

    func ownsConnection(
        client: SSHClient,
        startToken: StartToken,
        for entityId: UUID
    ) -> Bool {
        let identifier = ObjectIdentifier(client)
        if let registration = registrations[entityId] {
            return ObjectIdentifier(registration.client) == identifier
                && registration.startToken == startToken
        }
        if let context = startsInFlight[entityId] {
            return ObjectIdentifier(context.client) == identifier
                && context.token == startToken
        }
        return false
    }

    func client(for entityId: UUID) -> SSHClient? {
        registrations[entityId]?.client
    }

    func connectionClient(for entityId: UUID) -> SSHClient? {
        registrations[entityId]?.client ?? startsInFlight[entityId]?.client
    }

    func connectionStartToken(for entityId: UUID) -> StartToken? {
        registrations[entityId]?.startToken ?? startsInFlight[entityId]?.token
    }

    func owns(startToken: StartToken, for entityId: UUID) -> Bool {
        connectionStartToken(for: entityId) == startToken
    }

    func hasOtherClientReferences(using client: SSHClient, excluding entityId: UUID) -> Bool {
        let identifier = ObjectIdentifier(client)
        let hasRegistration = registrations.contains { registration in
            registration.key != entityId && ObjectIdentifier(registration.value.client) == identifier
        }
        let hasPendingStart = startsInFlight.contains { start in
            start.key != entityId && ObjectIdentifier(start.value.client) == identifier
        }
        return hasRegistration || hasPendingStart
    }

    func hasClientReferences(_ client: SSHClient) -> Bool {
        hasActiveRegistration(using: client) || hasPendingStart(using: client)
    }

    func hasActiveRegistration(using client: SSHClient) -> Bool {
        let identifier = ObjectIdentifier(client)
        return registrations.values.contains { ObjectIdentifier($0.client) == identifier }
    }

    func hasPendingStart(using client: SSHClient) -> Bool {
        let identifier = ObjectIdentifier(client)
        return startsInFlight.values.contains { ObjectIdentifier($0.client) == identifier }
    }

    func firstRegisteredClient(for serverId: UUID) -> SSHClient? {
        registrations.values.first(where: { $0.serverId == serverId })?.client
    }

    func firstPendingClient(for serverId: UUID) -> SSHClient? {
        startsInFlight.values.first(where: { $0.serverId == serverId })?.client
    }

    mutating func drain() -> DrainResult {
        let result = DrainResult(
            registrations: Array(registrations.values),
            pendingStarts: Array(startsInFlight.values)
        )
        registrations.removeAll()
        startsInFlight.removeAll()
        return result
    }

    mutating func removeAll() {
        _ = drain()
    }
}
