import Foundation
import os.log

#if os(iOS)
import ActivityKit
import Dispatch
#endif

@MainActor
private final class DisabledTerminalLiveActivityController: TerminalLiveActivityControlling {
    func reconcile(toward target: TerminalLiveActivityTarget) async {}

    func endForApplicationTermination() -> Bool {
        true
    }
}

#if os(iOS)
@available(iOS 16.1, *)
@MainActor
private final class ActivityKitTerminalLiveActivityController: TerminalLiveActivityControlling {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "LiveActivity"
    )
    private var reconciledTarget: TerminalLiveActivityTarget?

    func reconcile(toward target: TerminalLiveActivityTarget) async {
        let activities = Activity<VVTermActivityAttributes>.activities
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            for activity in activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            reconciledTarget = .end
            return
        }

        guard case .active(let snapshot) = target else {
            for activity in activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            reconciledTarget = .end
            return
        }

        let contentState = VVTermActivityAttributes.ContentState(
            status: activityStatus(for: snapshot.status),
            activeCount: snapshot.activeCount
        )

        if let activity = activities.first {
            for duplicate in activities.dropFirst() {
                await duplicate.end(dismissalPolicy: .immediate)
            }
            guard reconciledTarget != target || activities.count > 1 else {
                return
            }
            await activity.update(using: contentState)
            reconciledTarget = target
            return
        }

        do {
            let attributes = VVTermActivityAttributes(appName: "VVTerm")
            _ = try Activity.request(
                attributes: attributes,
                contentState: contentState,
                pushType: nil
            )
            reconciledTarget = target
        } catch {
            reconciledTarget = nil
            logger.error("Failed to start Live Activity: \(String(describing: error))")
        }
    }

    func endForApplicationTermination() -> Bool {
        let completion = DispatchSemaphore(value: 0)
        Task.detached(priority: .high) {
            defer { completion.signal() }
            for activity in Activity<VVTermActivityAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
        }

        let completed = completion.wait(timeout: .now() + 2) == .success
        if completed {
            reconciledTarget = .end
        } else {
            logger.error("Timed out ending Live Activities during application termination")
        }
        return completed
    }

    private func activityStatus(
        for status: TerminalLiveActivitySnapshot.Status
    ) -> VVTermLiveActivityStatus {
        switch status {
        case .connected:
            return .connected
        case .connecting:
            return .connecting
        case .reconnecting:
            return .reconnecting
        }
    }
}
#endif

@MainActor
private enum TerminalLiveActivityLiveComposition {
    static let shared: LiveActivityManager = {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            return LiveActivityManager(controller: ActivityKitTerminalLiveActivityController())
        }
        #endif
        return LiveActivityManager(controller: DisabledTerminalLiveActivityController())
    }()
}

extension LiveActivityManager {
    static var shared: LiveActivityManager {
        TerminalLiveActivityLiveComposition.shared
    }
}
