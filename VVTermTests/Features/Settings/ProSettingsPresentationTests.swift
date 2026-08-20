import XCTest
@testable import VVTerm

final class ProSettingsPresentationTests: XCTestCase {
    func testLifetimeAccessDoesNotExposeSubscriptionExpirationAsPurchaseDate() {
        let renewalDate = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = StoreEntitlementSnapshot(
            accessState: .pro,
            hasLifetimeAccess: true,
            subscriptionStatus: subscriptionStatus(
                productID: VVTermProducts.proYearly,
                expirationDate: renewalDate
            )
        )

        let state = ProSettingsUserState(snapshot: snapshot)

        XCTAssertEqual(state, .lifetime)
        XCTAssertNil(state.renewalDate)
        XCTAssertNil(state.primaryAction)
        XCTAssertEqual(String(localized: state.title), "Pro Lifetime")
    }

    func testYearlySubscriptionShowsRenewalAndManagement() {
        let renewalDate = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = StoreEntitlementSnapshot(
            accessState: .pro,
            hasLifetimeAccess: false,
            subscriptionStatus: subscriptionStatus(
                productID: VVTermProducts.proYearly,
                expirationDate: renewalDate
            )
        )

        let state = ProSettingsUserState(snapshot: snapshot)

        XCTAssertEqual(state, .subscription(plan: .yearly, renewalDate: renewalDate))
        XCTAssertEqual(state.renewalDate, renewalDate)
        XCTAssertEqual(state.primaryAction, .manageSubscription)
        XCTAssertEqual(String(localized: state.title), "Pro Yearly")
    }

    func testFreeTierOffersPlansWithoutProFeatures() {
        let state = ProSettingsUserState(snapshot: .free)

        XCTAssertEqual(state, .free)
        XCTAssertEqual(state.primaryAction, .viewPlans)
        XCTAssertFalse(state.hasProAccess)
        XCTAssertEqual(String(localized: state.title), "Free Tier")
    }

    func testCheckingStateHasNoAction() {
        let state = ProSettingsUserState(snapshot: .checking)

        XCTAssertEqual(state, .checking)
        XCTAssertNil(state.primaryAction)
        XCTAssertFalse(state.hasProAccess)
    }

    private func subscriptionStatus(
        productID: String,
        expirationDate: Date?
    ) -> StoreSubscriptionStatus {
        StoreSubscriptionStatus(
            transaction: .verified(
                StoreSubscriptionTransaction(
                    productID: productID,
                    expirationDate: expirationDate
                )
            ),
            state: .subscribed
        )
    }
}
