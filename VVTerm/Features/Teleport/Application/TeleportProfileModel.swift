import Combine
import Foundation
import TeleportKit

@MainActor
final class TeleportProfileModel: ObservableObject {
    typealias BrowserFactory = @MainActor @Sendable (
        @escaping @MainActor @Sendable () -> Void
    ) throws -> any TeleportBrowserSession

    enum Operation: Equatable {
        case idle
        case loading
        case signingIn
        case deletingCredential
        case loadingNodes
        case signingOut
    }

    @Published private(set) var summary: TeleportAccessSummary?
    @Published private(set) var discovery: TeleportDiscovery?
    @Published private(set) var nodePage: TeleportNodePage?
    @Published private(set) var operation = Operation.idle
    @Published private(set) var failure: (operation: Operation, message: String)?

    let profile: TeleportProfileConfiguration
    private let service: TeleportAccessService
    private var operationTask: Task<Void, Never>?
    private var browser: (any TeleportBrowserSession)?

    init(profile: TeleportProfileConfiguration, service: TeleportAccessService) {
        self.profile = profile
        self.service = service
    }

    #if DEBUG
    /// Display fixtures do not create keys or contact a server.
    convenience init(
        profile: TeleportProfileConfiguration, service: TeleportAccessService,
        summary: TeleportAccessSummary?, discovery: TeleportDiscovery
    ) {
        self.init(profile: profile, service: service)
        self.summary = summary
        self.discovery = discovery
    }
    #endif

    var isBusy: Bool { operation != .idle }
    var errorMessage: String? { failure?.message }

    nonisolated static func singleNode(
        in nodes: [TeleportNode], hasMore: Bool, currentNodeID: String, isFirstPage: Bool
    ) -> TeleportNode? {
        guard currentNodeID.isEmpty, isFirstPage, !hasMore, nodes.count == 1 else { return nil }
        return nodes[0]
    }

    func load() {
        perform(.loading) { model in
            model.discovery = nil
            model.nodePage = nil
            let summary = try await model.service.summary(for: model.profile)
            try Task.checkCancellation()
            model.summary = summary
            let discovery = try await model.service.discovery(for: model.profile)
            try Task.checkCancellation()
            model.discovery = discovery
            if let summary, summary.validBefore > Date() {
                try await model.readNodes(startKey: "")
            }
        }
    }

    func signIn(makeBrowserSession: @escaping BrowserFactory) {
        perform(.signingIn) { model in
            let summary = try await model.service.signIn(
                profile: model.profile,
                prompt: String(localized: "Approve Teleport sign-in with Face ID or Touch ID.")
            ) { [weak model] in
                try Task.checkCancellation()
                guard let model else { throw CancellationError() }
                return try model.startBrowser(makeBrowserSession)
            }
            try Task.checkCancellation()
            model.browser?.cancel()
            model.browser = nil
            model.summary = summary
            model.nodePage = nil
            try await model.readNodes(startKey: "")
        }
    }

    func deleteSecureEnclaveCredential() {
        perform(.deletingCredential) { model in
            try await model.service.deleteSecureEnclaveCredential(profile: model.profile)
            try Task.checkCancellation()
        }
    }

    func loadNodes(startKey: String = "") {
        perform(.loadingNodes) { model in
            try await model.readNodes(startKey: startKey)
        }
    }

    func signOut() {
        perform(.signingOut) { model in
            try await model.service.signOut(profile: model.profile)
            try Task.checkCancellation()
            model.summary = nil
            model.nodePage = nil
        }
    }

    func cancel() {
        operationTask?.cancel()
        operationTask = nil
        browser?.cancel()
        browser = nil
        operation = .idle
    }

    private func readNodes(startKey: String) async throws {
        try Task.checkCancellation()
        operation = .loadingNodes
        let page = try await service.nodes(for: profile, startKey: startKey)
        try Task.checkCancellation()
        nodePage = page
    }

    private func startBrowser(_ factory: BrowserFactory) throws -> any TeleportBrowserSession {
        let browser = try factory { [weak self] in self?.cancel() }
        self.browser = browser
        return browser
    }

    private func perform(
        _ operation: Operation,
        work: @escaping @MainActor (TeleportProfileModel) async throws -> Void
    ) {
        cancel()
        failure = nil
        self.operation = operation
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await work(self)
                try Task.checkCancellation()
            } catch {
                guard !Task.isCancelled else { return }
                failure = (self.operation, TeleportAccessError.message(for: error))
            }
            guard !Task.isCancelled else { return }
            browser?.cancel()
            browser = nil
            self.operation = .idle
            operationTask = nil
        }
    }
}
