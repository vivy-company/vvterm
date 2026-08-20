import Foundation

nonisolated struct StoreProduct: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let displayPrice: String
}

nonisolated enum StorePurchaseResult: Equatable, Sendable {
    case verified(productId: String)
    case unverified(productId: String)
    case userCancelled
    case pending
    case unknown
}

nonisolated enum StoreTransactionUpdate: Equatable, Sendable {
    case verified(productId: String)
    case unverified(productId: String)
}

nonisolated enum StoreSubscriptionState: Equatable, Sendable {
    case subscribed
    case inGracePeriod
    case inBillingRetryPeriod
    case expired
    case revoked
    case unknown
}

nonisolated struct StoreSubscriptionEntitlement: Equatable, Sendable {
    let state: StoreSubscriptionState
    let isVerified: Bool
}

nonisolated enum StoreVerificationResult<Value: Equatable & Sendable>: Equatable, Sendable {
    case verified(Value)
    case unverified
}

nonisolated struct StoreSubscriptionTransaction: Equatable, Sendable {
    let productID: String
    let expirationDate: Date?
}

nonisolated struct StoreSubscriptionStatus: Equatable, Sendable {
    let transaction: StoreVerificationResult<StoreSubscriptionTransaction>
    let state: StoreSubscriptionState

    var expirationDate: Date? {
        guard case .verified(let transaction) = transaction else { return nil }
        return transaction.expirationDate
    }
}

nonisolated enum PurchaseState: Equatable {
    case idle
    case purchasing
    case purchased
    case failed(String)

    static func == (lhs: PurchaseState, rhs: PurchaseState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.purchasing, .purchasing), (.purchased, .purchased):
            return true
        case (.failed(let lhsMessage), .failed(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

nonisolated enum RestoreState: Equatable {
    case idle
    case restoring
    case restored(hasAccess: Bool)
    case failed(String)

    static func == (lhs: RestoreState, rhs: RestoreState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.restoring, .restoring):
            return true
        case (.restored(let lhsHasAccess), .restored(let rhsHasAccess)):
            return lhsHasAccess == rhsHasAccess
        case (.failed(let lhsMessage), .failed(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

nonisolated enum PaywallSource: String, Equatable, Sendable {
    case general
    case serverLimit = "server_limit"
    case workspaceLimit = "workspace_limit"
    case tabLimit = "tab_limit"
    case fileTabLimit = "file_tab_limit"
    case splitPane = "split_pane"
    case customEnvironment = "custom_environment"
    case snippetLimit = "snippet_limit"
    case welcome
    case settings
    case sidebarBanner = "sidebar_banner"
    case dockerStats = "docker_stats"
}

nonisolated enum VVTermProducts {
    static let proMonthly = "com.vivy.vivyterm.pro.monthly"
    static let proYearly = "com.vivy.vivyterm.pro.yearly"
    static let proLifetime = "com.vivy.vivyterm.pro.lifetime"

    static let subscriptionGroupId = "vivyterm_pro"
    static let allProducts = [proMonthly, proYearly, proLifetime]
}

nonisolated enum StoreError: Error {
    case verificationFailed
    case productNotFound
    case purchaseFailed(String)
}
