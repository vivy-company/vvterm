import Combine
import Foundation
import TeleportKit

@MainActor
final class TeleportProfileModel: ObservableObject {
    typealias BrowserFactory = @MainActor (
        @escaping @MainActor @Sendable () -> Void
    ) throws -> any TeleportBrowserSession

    enum BrowserLogin: Sendable {
        case localMFA(password: String)
        case sso(TeleportConnector)
    }

    enum Operation: Equatable {
        case idle
        case loading
        case passwordLogin
        case browserLogin
        case biometricLogin
        case registeringCredential
        case deletingCredential
        case loadingNodes
        case signingOut

        var isDeviceAuthentication: Bool {
            switch self {
            case .biometricLogin, .registeringCredential, .deletingCredential: true
            default: false
            }
        }
    }

    enum CredentialResult: Equatable { case codeRequired, registered, deleted }

    @Published private(set) var summary: TeleportAccessSummary?
    @Published private(set) var discovery: TeleportDiscovery?
    @Published private(set) var nodePage: TeleportNodePage?
    @Published private(set) var operation = Operation.idle
    @Published private(set) var failure: (operation: Operation, message: String)?
    @Published private(set) var credentialResult: CredentialResult?

    let profile: TeleportProfileConfiguration
    private let service: TeleportAccessService
    private var operationTask: Task<Void, Never>?
    private var browser: (any TeleportBrowserSession)?

    init(profile: TeleportProfileConfiguration, service: TeleportAccessService) {
        self.profile = profile
        self.service = service
    }

    #if DEBUG
    /// UI fixtures supply display facts without creating credentials or contacting a server.
    convenience init(
        profile: TeleportProfileConfiguration, service: TeleportAccessService,
        summary: TeleportAccessSummary?, discovery: TeleportDiscovery,
        credentialResult: CredentialResult? = nil
    ) {
        self.init(profile: profile, service: service)
        self.summary = summary
        self.discovery = discovery
        self.credentialResult = credentialResult
    }
    #endif

    var isBusy: Bool { operation != .idle }
    var errorMessage: String? { failure?.message }

    nonisolated static func isValidOneTimeCode(_ code: String) -> Bool {
        (6...8).contains(code.utf8.count) && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    nonisolated static func singleNode(
        in nodes: [TeleportNode], hasMore: Bool, currentNodeID: String, isFirstPage: Bool
    ) -> TeleportNode? {
        guard currentNodeID.isEmpty, isFirstPage, !hasMore, nodes.count == 1 else { return nil }
        return nodes[0]
    }

    var canRegisterCredential: Bool {
        discovery?.authenticationType == "local"
            && (summary.map { $0.account == profile.account && $0.validBefore > Date() } ?? false)
    }

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
        browser method: BrowserLogin,
        makeBrowserSession: @escaping BrowserFactory
    ) {
        perform(.browserLogin) { model in
            let browser = try model.startBrowser(makeBrowserSession)
            defer { browser.cancel() }
            let summary: TeleportAccessSummary
            switch method {
            case .localMFA(let password):
                summary = try await model.service.login(
                    profile: model.profile, password: password, presenter: browser
                )
            case .sso(let connector):
                summary = try await model.service.login(
                    profile: model.profile, connector: connector, presenter: browser
                )
            }
            try Task.checkCancellation()
            browser.cancel()
            model.browser = nil
            model.summary = summary
            model.nodePage = nil
            try await model.readNodes(startKey: "")
        }
    }

    func loginWithSecureEnclave(password: String) {
        perform(.biometricLogin) { model in
            let summary = try await model.service.loginWithSecureEnclave(
                profile: model.profile, password: password,
                prompt: String(localized: "Approve Teleport sign-in with Face ID or Touch ID.")
            )
            try Task.checkCancellation()
            model.summary = summary
            model.nodePage = nil
            try await model.readNodes(startKey: "")
        }
    }

    func registerSecureEnclaveCredential(
        name: String, otp: String = "", makeBrowserSession: BrowserFactory? = nil
    ) {
        perform(.registeringCredential) { model in
            guard otp.isEmpty || Self.isValidOneTimeCode(otp) else {
                throw TeleportAccessError.deviceSetupCodeRequired
            }
            let browser = try makeBrowserSession.map { try model.startBrowser($0) }
            defer { browser?.cancel() }
            do {
                try await model.service.registerSecureEnclaveCredential(
                    profile: model.profile, name: name, otp: otp, presenter: browser,
                    prompt: String(localized: "Set up Teleport sign-in with Face ID or Touch ID.")
                )
            } catch TeleportError.oneTimeCodeRequired {
                try Task.checkCancellation()
                model.credentialResult = .codeRequired
                return
            }
            try Task.checkCancellation()
            model.credentialResult = .registered
        }
    }

    func deleteSecureEnclaveCredential() {
        perform(.deletingCredential) { model in
            try await model.service.deleteSecureEnclaveCredential(profile: model.profile)
            try Task.checkCancellation()
            model.credentialResult = .deleted
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

    func cancelCredentialSetup() {
        if operation == .registeringCredential { cancel() }
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
        if operation != .registeringCredential || credentialResult != .codeRequired {
            credentialResult = nil
        }
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
