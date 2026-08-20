import Foundation

extension ProPlanKind {
    var title: String {
        switch self {
        case .monthly:
            return String(localized: "Monthly")
        case .yearly:
            return String(localized: "Yearly")
        case .lifetime:
            return String(localized: "Lifetime")
        }
    }

    var detail: String {
        switch self {
        case .monthly:
            return String(localized: "Flexible access to every Pro feature.")
        case .yearly:
            return String(localized: "Best value for ongoing terminal work.")
        case .lifetime:
            return String(localized: "Pay once and keep Pro access forever.")
        }
    }

    var badge: String? {
        self == .yearly ? String(localized: "Best value") : nil
    }
}

struct ProPlanPresentation {
    let plan: ProPlanKind
    let displayPrice: String
    let introductoryOfferState: ProPlanIntroductoryOfferState

    init(
        plan: ProPlanKind,
        displayPrice: String,
        introductoryOfferState: ProPlanIntroductoryOfferState = .unavailable
    ) {
        self.plan = plan
        self.displayPrice = displayPrice
        self.introductoryOfferState = plan == .yearly ? introductoryOfferState : .unavailable
    }

    var priceLine: String {
        if advertisesFreeTrial {
            return String(localized: "7 days free")
        }

        switch plan {
        case .monthly:
            return String(format: String(localized: "%@ per month"), displayPrice)
        case .yearly:
            return String(format: String(localized: "%@ per year"), displayPrice)
        case .lifetime:
            return String(format: String(localized: "%@ one time"), displayPrice)
        }
    }

    var detail: String {
        advertisesFreeTrial
            ? String(format: String(localized: "Then %@ per year."), displayPrice)
            : plan.detail
    }

    var purchaseButtonTitle: String {
        if plan == .lifetime {
            return String(format: String(localized: "Buy %@"), displayPrice)
        }
        if advertisesFreeTrial {
            return String(localized: "Start 7-Day Free Trial")
        }
        return String(format: String(localized: "Subscribe for %@"), displayPrice)
    }

    var renewalDisclosure: String {
        if plan == .lifetime {
            return String(localized: "One-time purchase. No subscription renewal.")
        }
        if advertisesFreeTrial {
            return String(
                format: String(localized: "7 days free, then %@ per year. Auto-renews until canceled."),
                displayPrice
            )
        }
        return String(localized: "Auto-renews until canceled.")
    }

    var planAccessibilityLabel: String {
        [plan.title, priceLine, detail].joined(separator: ". ")
    }

    var purchaseButtonAccessibilityLabel: String {
        advertisesFreeTrial
            ? [purchaseButtonTitle, renewalDisclosure].joined(separator: ". ")
            : purchaseButtonTitle
    }

    private var advertisesFreeTrial: Bool {
        introductoryOfferState == .eligibleForSevenDayFreeTrial
    }
}
