import Foundation

nonisolated enum ProSettingsUserState: Equatable, Sendable {
    case checking
    case free
    case pro
    case lifetime
    case subscription(plan: ProPlanKind, renewalDate: Date?)

    init(snapshot: StoreEntitlementSnapshot) {
        switch snapshot.accessState {
        case .checking:
            self = .checking
        case .free:
            self = .free
        case .pro:
            if snapshot.hasLifetimeAccess {
                self = .lifetime
                return
            }

            guard let status = snapshot.subscriptionStatus,
                  case .verified(let transaction) = status.transaction else {
                self = .pro
                return
            }

            switch transaction.productID {
            case VVTermProducts.proMonthly:
                self = .subscription(plan: .monthly, renewalDate: transaction.expirationDate)
            case VVTermProducts.proYearly:
                self = .subscription(plan: .yearly, renewalDate: transaction.expirationDate)
            case VVTermProducts.proLifetime:
                self = .lifetime
            default:
                self = .pro
            }
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .checking:
            "Checking..."
        case .free:
            "Free Tier"
        case .pro:
            "Pro"
        case .lifetime:
            "Pro Lifetime"
        case .subscription(let plan, _):
            switch plan {
            case .monthly:
                "Pro Monthly"
            case .yearly:
                "Pro Yearly"
            case .lifetime:
                "Pro Lifetime"
            }
        }
    }

    var renewalDate: Date? {
        guard case .subscription(_, let renewalDate) = self else { return nil }
        return renewalDate
    }

    var primaryAction: ProSettingsPrimaryAction? {
        switch self {
        case .free:
            .viewPlans
        case .pro, .subscription:
            .manageSubscription
        case .checking, .lifetime:
            nil
        }
    }

    var hasProAccess: Bool {
        switch self {
        case .pro, .lifetime, .subscription:
            true
        case .checking, .free:
            false
        }
    }
}

nonisolated enum ProSettingsPrimaryAction: Equatable, Sendable {
    case viewPlans
    case manageSubscription

    var title: LocalizedStringResource {
        switch self {
        case .viewPlans:
            "View Plans"
        case .manageSubscription:
            "Manage Subscription"
        }
    }
}
