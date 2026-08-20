import Foundation
import os

nonisolated enum SSHStartupStage: String, Sendable {
    case transportPreparation
    case dnsResolution
    case tcpAddressAttempt
    case sshHandshake
    case hostKeyVerification
    case authentication
    case remoteEnvironment
    case terminalType
    case shellChannel
    case ptyRequest
    case shellRequest
    case firstTerminalByte
    case moshBootstrap
    case moshEndpoint
    case moshUDPSession
    case sshFallback
    case connectionDeadline
}

nonisolated final class SSHStartupTrace: Sendable {
    struct Event: Equatable, Sendable {
        let stage: SSHStartupStage
        let stageMilliseconds: Int
        let totalMilliseconds: Int
        let outcome: String
        let detail: String
    }

    struct Token: Sendable {
        let stage: SSHStartupStage
        let startedAt: ContinuousClock.Instant
    }

    private let logger: Logger
    private let eventHandler: (@Sendable (Event) -> Void)?
    private let startedAt = ContinuousClock.now
    private let completedStages = OSAllocatedUnfairLock(initialState: Set<SSHStartupStage>())
    private let events = OSAllocatedUnfairLock(initialState: [Event]())

    init(
        logger: Logger,
        eventHandler: (@Sendable (Event) -> Void)? = nil
    ) {
        self.logger = logger
        self.eventHandler = eventHandler
    }

    func begin(_ stage: SSHStartupStage) -> Token {
        Token(stage: stage, startedAt: .now)
    }

    func end(
        _ token: Token,
        outcome: String = "ok",
        detail: String = "none"
    ) {
        record(
            token.stage,
            stageMilliseconds: Self.milliseconds(token.startedAt.duration(to: .now)),
            outcome: outcome,
            detail: detail
        )
    }

    func recordOnce(
        _ stage: SSHStartupStage,
        outcome: String = "ok",
        detail: String = "none"
    ) {
        let inserted = completedStages.withLock { stages in
            stages.insert(stage).inserted
        }
        guard inserted else { return }
        record(stage, stageMilliseconds: 0, outcome: outcome, detail: detail)
    }

    func record(
        _ stage: SSHStartupStage,
        stageMilliseconds: Int,
        outcome: String,
        detail: String
    ) {
        let totalMilliseconds = Self.milliseconds(startedAt.duration(to: .now))
        let event = Event(
            stage: stage,
            stageMilliseconds: stageMilliseconds,
            totalMilliseconds: totalMilliseconds,
            outcome: outcome,
            detail: detail
        )
        events.withLock { $0.append(event) }
        logger.info(
            "startup stage=\(stage.rawValue, privacy: .public) stageMs=\(stageMilliseconds) totalMs=\(totalMilliseconds) outcome=\(outcome, privacy: .public) detail=\(detail, privacy: .public)"
        )
        eventHandler?(event)
    }

    func snapshot() -> [Event] {
        events.withLock { $0 }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        guard rounded < Double(Int.max) else { return Int.max }
        return Int(rounded)
    }
}
