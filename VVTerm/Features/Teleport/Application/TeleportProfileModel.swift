import Combine
import Foundation
import TeleportKit

@MainActor
final class TeleportProfileModel: ObservableObject {
    enum Operation: Equatable {
        case idle
        case loading
        case passwordLogin
        case browserLogin
        case loadingNodes
        case signingOut
    }

    @Published private(set) var summary: TeleportAccessSummary?
    @Published private(set) var discovery: TeleportDiscovery?
    @Published private(set) var nodePage: TeleportNodePage?
    @Published private(set) var operation = Operation.idle
    @Published private(set) var errorMessage: String?

    private let profile: TeleportProfileConfiguration
    private let service: TeleportAccessService
    private var operationTask: Task<Void, Never>?
    private var browser: (any TeleportBrowserSession)?

    init(profile: TeleportProfileConfiguration, service: TeleportAccessService) {
        self.profile = profile
        self.service = service
    }

    var isBusy: Bool { operation != .idle }

    var connectors: [TeleportConnector] {
        guard let discovery else { return [] }
        guard let connectorID = profile.connectorID else { return discovery.connectors }
        return discovery.connectors.filter { $0.id == connectorID }
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

    func login(password: String, otp: String) {
        perform(.passwordLogin) { model in
            let summary = try await model.service.login(
                profile: model.profile, password: password, otp: otp
            )
            try Task.checkCancellation()
            model.summary = summary
            model.nodePage = nil
            try await model.readNodes(startKey: "")
        }
    }

    func login(
        connector: TeleportConnector,
        makeBrowserSession: @escaping @MainActor (
            @escaping @MainActor @Sendable () -> Void
        ) throws -> any TeleportBrowserSession
    ) {
        perform(.browserLogin) { model in
            let browser = try makeBrowserSession { [weak model] in
                model?.cancel()
            }
            model.browser = browser
            defer { browser.cancel() }
            let summary = try await model.service.login(
                profile: model.profile, connector: connector, presenter: browser
            )
            try Task.checkCancellation()
            browser.cancel()
            model.browser = nil
            model.summary = summary
            model.nodePage = nil
            try await model.readNodes(startKey: "")
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
        let page = try await service.nodes(for: profile, startKey: startKey)
        try Task.checkCancellation()
        nodePage = page
    }

    private func perform(
        _ operation: Operation,
        work: @escaping @MainActor (TeleportProfileModel) async throws -> Void
    ) {
        cancel()
        errorMessage = nil
        self.operation = operation
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await work(self)
                try Task.checkCancellation()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = TeleportAccessError.message(for: error)
            }
            guard !Task.isCancelled else { return }
            browser?.cancel()
            browser = nil
            self.operation = .idle
            operationTask = nil
        }
    }
}
