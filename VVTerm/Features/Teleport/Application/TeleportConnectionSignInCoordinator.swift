import Combine
import Foundation
import TeleportKit

/// One window owns its sign-in request. The caller resumes before any transport starts.
@MainActor
final class TeleportConnectionSignInCoordinator: ObservableObject {
    typealias Authentication = @MainActor @Sendable (
        TeleportProfileConfiguration,
        @escaping @MainActor @Sendable () throws -> any TeleportBrowserSession
    ) async throws -> Void

    nonisolated struct Request: Identifiable {
        let id: UUID
        let server: Server
        private let continuation: CheckedContinuation<Bool, Never>

        fileprivate init(id: UUID, server: Server, continuation: CheckedContinuation<Bool, Never>) {
            self.id = id
            self.server = server
            self.continuation = continuation
        }

        fileprivate func resume(returning result: Bool) {
            continuation.resume(returning: result)
        }
    }

    private enum State {
        case idle
        case checking(Request, Task<Void, Never>)
        case waiting(Request)
        case signingIn(Request, Task<Void, Never>, (any TeleportBrowserSession)?)
        case failed(Request, String)

        var attempt: Request? {
            switch self {
            case .idle: nil
            case .checking(let request, _), .waiting(let request),
                 .signingIn(let request, _, _), .failed(let request, _): request
            }
        }
    }

    @Published private var state = State.idle
    private let summary: @Sendable (TeleportProfileConfiguration) async throws -> TeleportAccessSummary?
    private let currentServer: @MainActor (UUID) -> Server?
    private let now: @Sendable () -> Date

    var request: Request? {
        switch state {
        case .waiting(let request), .signingIn(let request, _, _), .failed(let request, _): request
        case .idle, .checking: nil
        }
    }

    var failureMessage: String? {
        guard case .failed(_, let message) = state else { return nil }
        return message
    }

    init(
        summary: @escaping @Sendable (TeleportProfileConfiguration) async throws -> TeleportAccessSummary?,
        currentServer: @escaping @MainActor (UUID) -> Server?,
        now: @escaping @Sendable () -> Date
    ) {
        self.summary = summary
        self.currentServer = currentServer
        self.now = now
    }

    func ensureAccess(for server: Server) async -> Bool {
        guard server.connectionMode == .teleport else { return true }
        guard !Task.isCancelled, let profile = server.teleportConfiguration?.profile,
              matchesCurrentServer(server), case .idle = state else { return false }
        let id = UUID()
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, matchesCurrentServer(server),
                      case .idle = state else {
                    continuation.resume(returning: false)
                    return
                }
                let request = Request(id: id, server: server, continuation: continuation)
                let summary = self.summary
                let task = Task<Void, Never> { [weak self] in
                    guard !Task.isCancelled else { return }
                    let stored = try? await summary(profile)
                    self?.checked(stored, requestID: id)
                }
                state = .checking(request, task)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        return allowed && !Task.isCancelled
    }

    func signIn(
        _ requestID: UUID,
        authenticate: @escaping Authentication,
        makeBrowserSession: @escaping TeleportProfileModel.BrowserFactory,
        authorize: @escaping @MainActor @Sendable (Server) async -> Bool
    ) {
        let request: Request
        switch state {
        case .waiting(let current), .failed(let current, _): request = current
        default: return
        }
        guard request.id == requestID, matchesCurrentServer(request.server),
              let profile = request.server.teleportConfiguration?.profile else {
            cancel(requestID)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await authenticate(profile) { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try self.startBrowser(requestID, factory: makeBrowserSession)
                }
                try Task.checkCancellation()
                closeBrowser(requestID)
                guard self.request?.id == requestID, matchesCurrentServer(request.server),
                      await authorize(request.server), !Task.isCancelled else {
                    cancel(requestID)
                    return
                }
                guard await complete(requestID) else {
                    fail(requestID, error: TeleportError.invalidCertificate("saved access"))
                    return
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    cancel(requestID)
                } else {
                    fail(requestID, error: error)
                }
            }
        }
        state = .signingIn(request, task, nil)
    }

    func savedServersDidChange(_ servers: [Server]) {
        guard let attempt = state.attempt else { return }
        if !matchesCurrentServer(attempt.server, current: servers.first { $0.id == attempt.server.id }) {
            cancel(attempt.id)
        }
    }

    /// Authentication success alone is insufficient; read the stored identity again.
    func complete(_ requestID: UUID) async -> Bool {
        guard let request, request.id == requestID else { return false }
        guard !Task.isCancelled, matchesCurrentServer(request.server),
              let profile = request.server.teleportConfiguration?.profile else {
            cancel(requestID)
            return false
        }
        return await withTaskCancellationHandler {
            let stored = try? await summary(profile)
            guard self.request?.id == requestID else { return false }
            guard !Task.isCancelled, matchesCurrentServer(request.server) else {
                cancel(requestID)
                return false
            }
            guard Self.isUsable(stored, for: request.server, at: now()) else { return false }
            finish(requestID, returning: true)
            return true
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID) }
        }
    }

    func cancel(_ requestID: UUID) {
        finish(requestID, returning: false)
    }

    func cancel() {
        guard let attempt = state.attempt else { return }
        cancel(attempt.id)
    }

    nonisolated static func isUsable(
        _ summary: TeleportAccessSummary?, for server: Server, at date: Date
    ) -> Bool {
        guard server.connectionMode == .teleport, let configuration = server.teleportConfiguration,
              let summary, summary.account == configuration.profile.account,
              summary.clusterName == configuration.clusterName,
              summary.allowedLogins.contains(server.username) else { return false }
        let remaining = summary.validBefore.timeIntervalSince(date)
        return remaining.isFinite && remaining > 0
    }

    private func checked(_ stored: TeleportAccessSummary?, requestID: UUID) {
        guard case .checking(let request, _) = state, request.id == requestID else { return }
        guard !Task.isCancelled, matchesCurrentServer(request.server) else {
            cancel(requestID)
            return
        }
        if Self.isUsable(stored, for: request.server, at: now()) {
            finish(requestID, returning: true)
        } else {
            state = .waiting(request)
        }
    }

    private func matchesCurrentServer(_ server: Server) -> Bool {
        matchesCurrentServer(server, current: currentServer(server.id))
    }

    private func matchesCurrentServer(_ server: Server, current: Server?) -> Bool {
        guard var current else { return false }
        // Connection reporting can refresh these facts while a sign-in is open.
        current.lastConnected = server.lastConnected
        current.detectedSystemIdentity = server.detectedSystemIdentity
        current.updatedAt = server.updatedAt
        return current == server
    }

    private func startBrowser(
        _ requestID: UUID, factory: TeleportProfileModel.BrowserFactory
    ) throws -> any TeleportBrowserSession {
        try Task.checkCancellation()
        guard case .signingIn(let request, let task, nil) = state,
              request.id == requestID, matchesCurrentServer(request.server) else {
            throw CancellationError()
        }
        let browser = try factory { [weak self] in self?.cancel(requestID) }
        guard case .signingIn(let current, _, nil) = state,
              current.id == requestID, !Task.isCancelled else {
            browser.cancel()
            throw CancellationError()
        }
        state = .signingIn(request, task, browser)
        return browser
    }

    private func closeBrowser(_ requestID: UUID) {
        guard case .signingIn(let request, let task, let browser) = state,
              request.id == requestID else { return }
        state = .signingIn(request, task, nil)
        browser?.cancel()
    }

    private func fail(_ requestID: UUID, error: any Error) {
        guard let request = state.attempt, request.id == requestID else { return }
        let previous = state
        state = .failed(request, TeleportAccessError.message(for: error))
        if case .signingIn(_, let task, let browser) = previous {
            task.cancel()
            browser?.cancel()
        }
    }

    private func finish(_ requestID: UUID, returning result: Bool) {
        guard let request = state.attempt, request.id == requestID else { return }
        let previous = state
        state = .idle
        if case .checking(_, let task) = previous { task.cancel() }
        if case .signingIn(_, let task, let browser) = previous {
            task.cancel()
            browser?.cancel()
        }
        request.resume(returning: result)
    }
}
