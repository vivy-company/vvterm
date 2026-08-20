import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

nonisolated enum CloudKitSyncLifecycleEvent: Equatable, Sendable {
    case foreground
    case syncEnabled
    case syncDisabled
}

@MainActor
final class CloudKitSyncLifecycleDriver {
    typealias Observer = (CloudKitSyncLifecycleEvent) -> Void

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let foregroundMinimumInterval: TimeInterval
    private let now: () -> Date
    private var observers: [UUID: Observer] = [:]
    private var foregroundObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastForegroundEventAt: Date = .distantPast
    private var lastKnownSyncEnabled: Bool

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        foregroundNotification: Notification.Name? = nil,
        foregroundMinimumInterval: TimeInterval = 20,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.foregroundMinimumInterval = foregroundMinimumInterval
        self.now = now
        self.lastKnownSyncEnabled = SyncSettings.isEnabled(in: defaults)
        let resolvedForegroundNotification = foregroundNotification ?? Self.platformForegroundNotification

        foregroundObserver = notificationCenter.addObserver(
            forName: resolvedForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleForeground()
            }
        }
        defaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDefaultsChange()
            }
        }
    }

    isolated deinit {
        if let foregroundObserver {
            notificationCenter.removeObserver(foregroundObserver)
        }
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
        }
    }

    @discardableResult
    func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func handleForeground() {
        guard SyncSettings.isEnabled(in: defaults) else { return }
        let eventDate = now()
        guard eventDate.timeIntervalSince(lastForegroundEventAt) >= foregroundMinimumInterval else {
            return
        }
        lastForegroundEventAt = eventDate
        publish(.foreground)
    }

    private func handleDefaultsChange() {
        let isEnabled = SyncSettings.isEnabled(in: defaults)
        guard isEnabled != lastKnownSyncEnabled else { return }
        lastKnownSyncEnabled = isEnabled
        publish(isEnabled ? .syncEnabled : .syncDisabled)
    }

    private func publish(_ event: CloudKitSyncLifecycleEvent) {
        for observer in Array(observers.values) {
            observer(event)
        }
    }

    private static var platformForegroundNotification: Notification.Name {
        #if os(iOS)
        UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        Notification.Name("VVTermApplicationDidBecomeActive")
        #endif
    }
}
