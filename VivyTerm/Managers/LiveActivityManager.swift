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
            await endActivityIfNeeded()
            return
        }

        let activeCount = sessions.filter { $0.connectionState.isConnected || $0.connectionState.isConnecting }.count
        if activeCount == 0 {
            await endActivityIfNeeded()
            return
        }

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
    private func endActivityIfNeeded() async {
        guard let activity else { return }
        await activity.end(dismissalPolicy: .immediate)
        self.activity = nil
        lastState = nil
    }
    #endif
}
