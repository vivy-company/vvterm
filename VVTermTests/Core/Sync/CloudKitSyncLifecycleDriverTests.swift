import XCTest
@testable import VVTerm

@MainActor
final class CloudKitSyncLifecycleDriverTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var notificationCenter: NotificationCenter!
    private let foregroundNotification = Notification.Name("CloudKitSyncLifecycleDriverTests.foreground")

    override func setUp() {
        super.setUp()
        suiteName = "CloudKitSyncLifecycleDriverTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: SyncSettings.enabledKey)
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        notificationCenter = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testForegroundEventsUseOneSharedThrottle() {
        var currentDate = Date(timeIntervalSince1970: 100)
        let driver = CloudKitSyncLifecycleDriver(
            defaults: defaults,
            notificationCenter: notificationCenter,
            foregroundNotification: foregroundNotification,
            foregroundMinimumInterval: 20,
            now: { currentDate }
        )
        var firstEvents: [CloudKitSyncLifecycleEvent] = []
        var secondEvents: [CloudKitSyncLifecycleEvent] = []
        _ = driver.observe { firstEvents.append($0) }
        _ = driver.observe { secondEvents.append($0) }

        notificationCenter.post(name: foregroundNotification, object: nil)
        currentDate.addTimeInterval(19)
        notificationCenter.post(name: foregroundNotification, object: nil)
        currentDate.addTimeInterval(1)
        notificationCenter.post(name: foregroundNotification, object: nil)

        XCTAssertEqual(firstEvents, [.foreground, .foreground])
        XCTAssertEqual(secondEvents, firstEvents)
    }

    func testSyncTogglePublishesOnlyEffectiveChangesAndBlocksForegroundWhenDisabled() {
        let driver = CloudKitSyncLifecycleDriver(
            defaults: defaults,
            notificationCenter: notificationCenter,
            foregroundNotification: foregroundNotification
        )
        var events: [CloudKitSyncLifecycleEvent] = []
        let observerID = driver.observe { events.append($0) }

        defaults.set(false, forKey: SyncSettings.enabledKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        notificationCenter.post(name: foregroundNotification, object: nil)
        defaults.set(true, forKey: SyncSettings.enabledKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)

        XCTAssertEqual(events, [.syncDisabled, .syncEnabled])

        driver.removeObserver(observerID)
        notificationCenter.post(name: foregroundNotification, object: nil)
        XCTAssertEqual(events, [.syncDisabled, .syncEnabled])
    }
}
