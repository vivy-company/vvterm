import Foundation
import os.log
#if os(iOS)
import ActivityKit
#endif

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VivyTerm", category: "LiveActivity")

    private init() {}

    func refresh(with sessions: [ConnectionSession]) {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            Task { await updateActivity(for: sessions) }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private var activity: Activity<VivyTermActivityAttributes>?

    @available(iOS 16.1, *)
    private var lastState: VivyTermActivityAttributes.ContentState?

    @available(iOS 16.1, *)
    private func updateActivity(for sessions: [ConnectionSession]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities()
            return
        }

        let activeCount = sessions.filter { $0.connectionState.isConnected || $0.connectionState.isConnecting }.count
        if activeCount == 0 {
            await endAllActivities()
            return
        }

        await attachToExistingActivityIfNeeded()

        let status: VivyTermLiveActivityStatus
        if sessions.contains(where: { if case .reconnecting = $0.connectionState { return true } else { return false } }) {
            status = .reconnecting
        } else if sessions.contains(where: { if case .connecting = $0.connectionState { return true } else { return false } }) {
            status = .connecting
        } else if sessions.contains(where: { $0.connectionState.isConnected }) {
            status = .connected
        } else {
            status = .disconnected
        }

        let newState = VivyTermActivityAttributes.ContentState(status: status, activeCount: activeCount)
        if activity == nil {
            do {
                let attributes = VivyTermActivityAttributes(appName: "VVTerm")
                activity = try Activity.request(attributes: attributes, contentState: newState, pushType: nil)
                lastState = newState
            } catch {
                logger.error("Failed to start Live Activity: \(String(describing: error))")
            }
            return
        }

        guard newState != lastState else { return }
        await activity?.update(using: newState)
        lastState = newState
    }

    @available(iOS 16.1, *)
    private func attachToExistingActivityIfNeeded() async {
        guard activity == nil else { return }
        let existing = Activity<VivyTermActivityAttributes>.activities
        guard let current = existing.first else { return }
        activity = current

        if existing.count > 1 {
            for duplicate in existing.dropFirst() {
                await duplicate.end(dismissalPolicy: .immediate)
            }
        }
    }

    @available(iOS 16.1, *)
    private func endAllActivities() async {
        let existing = Activity<VivyTermActivityAttributes>.activities
        for activity in existing {
            await activity.end(dismissalPolicy: .immediate)
        }
        self.activity = nil
        lastState = nil
    }
    #endif
}
