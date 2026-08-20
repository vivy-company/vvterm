import Foundation
import Cloudflared
import os.log

nonisolated struct CloudflareMetadataBodyBudget: Sendable {
    private(set) var receivedBytes = 0
    let maximumBytes: Int

    func validateExpectedContentLength(_ expectedContentLength: Int64) throws {
        guard expectedContentLength < 0 || expectedContentLength <= Int64(maximumBytes) else {
            throw CloudflareMetadataRequestError.responseTooLarge
        }
    }

    mutating func record(byteCount: Int) throws {
        guard byteCount >= 0,
              byteCount <= maximumBytes - min(receivedBytes, maximumBytes) else {
            throw CloudflareMetadataRequestError.responseTooLarge
        }
        receivedBytes += byteCount
    }
}

nonisolated enum CloudflareMetadataRequestError: LocalizedError {
    case nonHTTPResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "Cloudflare metadata returned a non-HTTP response."
        case .responseTooLarge:
            return "Cloudflare metadata response exceeded the allowed size."
        }
    }
}

nonisolated struct CloudflareTransportSession: Sendable {
    let connect: @Sendable (String, Cloudflared.AuthMethod) async throws -> UInt16
    let disconnect: @Sendable () async -> Void
}

typealias CloudflareTransportSessionFactory = @Sendable (
    any AuthProviding
) -> CloudflareTransportSession

actor CloudflareTransportManager {
    private enum SessionState {
        case idle
        case preparing(UUID)
        case connecting(UUID, CloudflareTransportSession)
        case connected(UUID, CloudflareTransportSession)

        var operationID: UUID? {
            switch self {
            case .idle:
                return nil
            case .preparing(let operationID),
                 .connecting(let operationID, _),
                 .connected(let operationID, _):
                return operationID
            }
        }

        var session: CloudflareTransportSession? {
            switch self {
            case .connecting(_, let session), .connected(_, let session):
                return session
            case .idle, .preparing:
                return nil
            }
        }
    }

    private struct AccessMetadata: Sendable {
        let teamDomain: String
        let appDomain: String
    }
    private struct PersistedAccessMetadata: Codable {
        let teamDomain: String
        let appDomain: String
    }
    private enum RedirectPolicy: Sendable {
        case follow(maximumRedirects: Int)
        case block
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let policy: RedirectPolicy
        private let lock = NSLock()
        private var redirectCount = 0

        init(policy: RedirectPolicy) {
            self.policy = policy
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            switch policy {
            case .block:
                completionHandler(nil)
            case .follow(let maximumRedirects):
                let shouldFollow = lock.withLock {
                    redirectCount += 1
                    return redirectCount <= maximumRedirects
                }
                completionHandler(shouldFollow ? request : nil)
            }
        }
    }

    private struct BoundedMetadataHTTPClient: HTTPClient {
        let maximumBodyBytes: Int
        let timeout: TimeInterval
        let redirectPolicy: RedirectPolicy

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            var request = request
            request.timeoutInterval = timeout
            let delegate = RedirectDelegate(policy: redirectPolicy)
            let (bytes, rawResponse) = try await URLSession.shared.bytes(
                for: request,
                delegate: delegate
            )
            guard let response = rawResponse as? HTTPURLResponse else {
                throw CloudflareMetadataRequestError.nonHTTPResponse
            }

            var budget = CloudflareMetadataBodyBudget(maximumBytes: maximumBodyBytes)
            try budget.validateExpectedContentLength(response.expectedContentLength)
            var data = Data()
            data.reserveCapacity(min(maximumBodyBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                try budget.record(byteCount: 1)
                data.append(byte)
            }
            return (data, response)
        }
    }

    private let callbackScheme = "vvterm-cfaccess"
    private let userAgent = "VVTerm"
    private let discoveryTimeout: TimeInterval = 12
    private let metadataBodyLimit = 32 * 1_024
    private let metadataRedirectLimit = 5
    private let disconnectTimeout: Duration = .seconds(4)
    private let metadataKeychain = KeychainStore(service: "app.vivy.vvterm.cloudflare.metadata")
    private let metadataStorageKey = "cache.v1"
    private let makeSession: CloudflareTransportSessionFactory
    private var sessionState: SessionState = .idle
    private var metadataCache: [String: AccessMetadata] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "CloudflareTransport")

    init(
        makeSession: @escaping CloudflareTransportSessionFactory = { authProvider in
            let session = SessionActor(
                authProvider: authProvider,
                tunnelProvider: CloudflareTunnelProvider(),
                retryPolicy: RetryPolicy(maxReconnectAttempts: 1, baseDelayNanoseconds: 500_000_000),
                oauthFallback: nil,
                sleep: { delay in
                    try? await Task.sleep(nanoseconds: delay)
                }
            )
            return CloudflareTransportSession(
                connect: { hostname, method in
                    try await session.connect(hostname: hostname, method: method)
                },
                disconnect: {
                    await session.disconnect()
                }
            )
        }
    ) {
        self.makeSession = makeSession
    }

    func connect(server: Server, credentials: ServerCredentials) async throws -> UInt16 {
        let operationID = UUID()
        let previousSession = sessionState.session
        sessionState = .preparing(operationID)
        if let previousSession {
            await disconnect(previousSession)
        }
        guard sessionState.operationID == operationID else {
            throw CancellationError()
        }

        let hostname = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            sessionState = .idle
            throw SSHError.cloudflareConfigurationRequired(
                String(localized: "Cloudflare transport requires a valid hostname.")
            )
        }

        let accessMode = server.cloudflareAccessMode ?? .oauth
        let metadata: AccessMetadata
        do {
            metadata = try await resolveAccessMetadata(
                for: hostname,
                server: server,
                mode: accessMode,
                operationID: operationID
            )
        } catch {
            if sessionState.operationID == operationID {
                sessionState = .idle
                throw error
            }
            throw CancellationError()
        }
        guard sessionState.operationID == operationID else {
            throw CancellationError()
        }

        let authProvider: any AuthProviding
        let authMethod: Cloudflared.AuthMethod

        switch accessMode {
        case .oauth:
            authProvider = OAuthProvider(
                flow: CloudflareOAuthFlow(userAgent: userAgent),
                tokenStore: CloudflareTokenStoreAdapter()
            )
            authMethod = .oauth(
                teamDomain: metadata.teamDomain,
                appDomain: metadata.appDomain,
                callbackScheme: callbackScheme
            )

        case .serviceToken:
            let clientID = credentials.cloudflareClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clientSecret = credentials.cloudflareClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !clientID.isEmpty else {
                sessionState = .idle
                throw SSHError.cloudflareConfigurationRequired(
                    String(localized: "Cloudflare service token client ID is required.")
                )
            }
            guard !clientSecret.isEmpty else {
                sessionState = .idle
                throw SSHError.cloudflareConfigurationRequired(
                    String(localized: "Cloudflare service token client secret is required.")
                )
            }

            authProvider = ServiceTokenProvider()
            authMethod = .serviceToken(
                teamDomain: metadata.teamDomain,
                clientID: clientID,
                clientSecret: clientSecret
            )
        }

        let session = makeSession(authProvider)
        sessionState = .connecting(operationID, session)

        do {
            let localPort = try await session.connect(hostname, authMethod)
            guard sessionState.operationID == operationID else {
                throw CancellationError()
            }
            sessionState = .connected(operationID, session)
            return localPort
        } catch is CancellationError {
            if sessionState.operationID == operationID {
                sessionState = .idle
                await disconnect(session)
            }
            throw CancellationError()
        } catch let failure as Failure {
            guard sessionState.operationID == operationID else {
                throw CancellationError()
            }
            sessionState = .idle
            await disconnect(session)
            throw mapFailure(failure)
        } catch {
            guard sessionState.operationID == operationID else {
                throw CancellationError()
            }
            sessionState = .idle
            await disconnect(session)
            throw SSHError.cloudflareTunnelFailed(error.localizedDescription)
        }
    }

    func disconnect() async {
        let session = sessionState.session
        sessionState = .idle
        guard let session else { return }
        await disconnect(session)
    }

    private func disconnect(_ session: CloudflareTransportSession) async {
        do {
            try await HardOperationDeadline.run(timeout: disconnectTimeout) {
                await session.disconnect()
            }
        } catch {
            logger.warning("Timed out while disconnecting Cloudflare transport session")
        }
    }

    private func resolveAccessMetadata(
        for hostname: String,
        server: Server,
        mode: CloudflareAccessMode,
        operationID: UUID
    ) async throws -> AccessMetadata {
        let cacheKey = metadataCacheKey(for: hostname)
        let teamOverride = server.cloudflareTeamDomainOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedHost = normalizedHostName(from: hostname)
        switch mode {
        case .oauth:
            // OAuth flow can resolve metadata during browser auth.
            // Keep this path host-driven so users only need to provide the SSH host.
            if !teamOverride.isEmpty {
                let metadata = AccessMetadata(teamDomain: teamOverride, appDomain: normalizedHost)
                metadataCache[cacheKey] = metadata
                persistMetadata(metadata, for: cacheKey)
                return metadata
            }
            clearCachedMetadata(for: cacheKey)

            // Last-resort hint for OAuth only (do not persist; may not be a real team domain).
            return AccessMetadata(teamDomain: normalizedHost, appDomain: normalizedHost)

        case .serviceToken:
            if !teamOverride.isEmpty {
                let metadata = AccessMetadata(
                    teamDomain: teamOverride,
                    appDomain: normalizedHost
                )
                metadataCache[cacheKey] = metadata
                persistMetadata(metadata, for: cacheKey)
                return metadata
            }

            if let cached = metadataCache[cacheKey] {
                return cached
            }
            if let persisted = loadPersistedMetadata(for: cacheKey) {
                metadataCache[cacheKey] = persisted
                return persisted
            }

            do {
                let discovered = try await discoverAccessMetadata(hostname: hostname)
                guard sessionState.operationID == operationID else {
                    throw CancellationError()
                }
                metadataCache[cacheKey] = discovered
                persistMetadata(discovered, for: cacheKey)
                return discovered
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SSHError.cloudflareConfigurationRequired(
                    String(
                        localized: "Could not auto-discover Cloudflare Team Domain (\(describeFailure(error))). Add Team Domain override (for example: team.cloudflareaccess.com)."
                    )
                )
            }
        }
    }

    private func normalizedHostName(from hostname: String) -> String {
        if let normalizedURL = try? URLTools.normalizeOriginURL(from: hostname),
           let host = normalizedURL.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }
        return hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metadataCacheKey(for hostname: String) -> String {
        hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func loadPersistedMetadata(for cacheKey: String) -> AccessMetadata? {
        guard
            let data = try? metadataKeychain.get(metadataStorageKey, scope: .deviceOnly),
            let persistedMap = try? JSONDecoder().decode([String: PersistedAccessMetadata].self, from: data),
            let persisted = persistedMap[cacheKey]
        else {
            return nil
        }
        return AccessMetadata(teamDomain: persisted.teamDomain, appDomain: persisted.appDomain)
    }

    private func persistMetadata(_ metadata: AccessMetadata, for cacheKey: String) {
        var persistedMap: [String: PersistedAccessMetadata] = [:]
        if let existingData = try? metadataKeychain.get(metadataStorageKey, scope: .deviceOnly),
           let decoded = try? JSONDecoder().decode([String: PersistedAccessMetadata].self, from: existingData) {
            persistedMap = decoded
        }

        persistedMap[cacheKey] = PersistedAccessMetadata(
            teamDomain: metadata.teamDomain,
            appDomain: metadata.appDomain
        )
        if let encoded = try? JSONEncoder().encode(persistedMap) {
            try? metadataKeychain.set(encoded, forKey: metadataStorageKey, scope: .deviceOnly)
        }
    }

    private func clearCachedMetadata(for cacheKey: String) {
        metadataCache.removeValue(forKey: cacheKey)
        guard
            let existingData = try? metadataKeychain.get(metadataStorageKey, scope: .deviceOnly),
            var persistedMap = try? JSONDecoder().decode([String: PersistedAccessMetadata].self, from: existingData),
            persistedMap.removeValue(forKey: cacheKey) != nil
        else {
            return
        }

        if persistedMap.isEmpty {
            try? metadataKeychain.delete(metadataStorageKey, scope: .deviceOnly)
            return
        }

        if let encoded = try? JSONEncoder().encode(persistedMap) {
            try? metadataKeychain.set(encoded, forKey: metadataStorageKey, scope: .deviceOnly)
        }
    }

    private func discoverMetadata(hostname: String) async throws -> AccessMetadata {
        let appURL = try URLTools.normalizeOriginURL(from: hostname)
        let appInfo = try await AppInfoResolver(
            client: BoundedMetadataHTTPClient(
                maximumBodyBytes: metadataBodyLimit,
                timeout: discoveryTimeout,
                redirectPolicy: .follow(maximumRedirects: metadataRedirectLimit)
            ),
            userAgent: userAgent
        ).resolve(appURL: appURL)
        return AccessMetadata(teamDomain: appInfo.authDomain, appDomain: appInfo.appDomain)
    }

    private func discoverAccessMetadata(hostname: String) async throws -> AccessMetadata {
        let appURL = try URLTools.normalizeOriginURL(from: hostname)
        if let strict = try? await discoverMetadata(hostname: hostname) {
            return strict
        }

        let appHost = appURL.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? hostname
        let normalizedAppDomain = appHost.isEmpty ? hostname : appHost
        var discoveryErrors: [String] = []
        let methods = ["HEAD", "GET"]

        for method in methods {
            do {
                if let followed = try await discoverByFollowingRedirect(appURL: appURL, method: method, appDomainFallback: normalizedAppDomain) {
                    return followed
                }
            } catch {
                discoveryErrors.append("\(method)-follow: \(describeFailure(error))")
            }
        }

        for method in methods {
            do {
                if let fromLocation = try await discoverByLocationHeader(appURL: appURL, method: method, appDomainFallback: normalizedAppDomain) {
                    return fromLocation
                }
            } catch {
                discoveryErrors.append("\(method)-location: \(describeFailure(error))")
            }
        }

        let details = discoveryErrors.isEmpty
            ? "no redirect host or Location header present"
            : discoveryErrors.joined(separator: "; ")
        throw Failure.protocolViolation("unable to derive Cloudflare team domain from Access redirect (\(details))")
    }

    private func discoverByFollowingRedirect(
        appURL: URL,
        method: String,
        appDomainFallback: String
    ) async throws -> AccessMetadata? {
        var request = URLRequest(url: appURL)
        request.httpMethod = method
        request.timeoutInterval = discoveryTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (_, response) = try await BoundedMetadataHTTPClient(
            maximumBodyBytes: metadataBodyLimit,
            timeout: discoveryTimeout,
            redirectPolicy: .follow(maximumRedirects: metadataRedirectLimit)
        ).send(request)

        guard let finalHost = response.url?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !finalHost.isEmpty,
              finalHost != appDomainFallback else {
            return nil
        }

        let discoveredAppDomain = response.value(forHTTPHeaderField: AccessHeader.appDomain)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appDomain = (discoveredAppDomain?.isEmpty == false) ? discoveredAppDomain! : appDomainFallback
        return AccessMetadata(teamDomain: finalHost, appDomain: appDomain)
    }

    private func discoverByLocationHeader(
        appURL: URL,
        method: String,
        appDomainFallback: String
    ) async throws -> AccessMetadata? {
        var request = URLRequest(url: appURL)
        request.httpMethod = method
        request.timeoutInterval = discoveryTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (_, response) = try await BoundedMetadataHTTPClient(
            maximumBodyBytes: metadataBodyLimit,
            timeout: discoveryTimeout,
            redirectPolicy: .block
        ).send(request)

        guard let location = response.value(forHTTPHeaderField: "Location"),
              let locationURL = URL(string: location, relativeTo: appURL),
              let teamHost = locationURL.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamHost.isEmpty else {
            return nil
        }

        let discoveredAppDomain = response.value(forHTTPHeaderField: AccessHeader.appDomain)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appDomain = (discoveredAppDomain?.isEmpty == false) ? discoveredAppDomain! : appDomainFallback
        return AccessMetadata(teamDomain: teamHost, appDomain: appDomain)
    }

    private func describeFailure(_ error: Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .invalidState(let message),
                 .auth(let message),
                 .configuration(let message),
                 .protocolViolation(let message),
                 .internalError(let message):
                return message
            case .transport(let message, _):
                return message
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? String(describing: error) : message
    }

    private func mapFailure(_ failure: Failure) -> SSHError {
        switch failure {
        case .auth(let message):
            return .cloudflareAuthenticationFailed(message)
        case .configuration(let message), .protocolViolation(let message):
            return .cloudflareConfigurationRequired(message)
        case .transport(let message, _):
            return .cloudflareTunnelFailed(message)
        case .invalidState(let message), .internalError(let message):
            return .cloudflareTunnelFailed(message)
        }
    }

}
