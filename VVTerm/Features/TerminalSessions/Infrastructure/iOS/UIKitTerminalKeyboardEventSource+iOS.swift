#if os(iOS)
import Foundation
import UIKit

@MainActor
final class UIKitTerminalKeyboardEventSource: TerminalKeyboardEventSource {
    private let center: NotificationCenter
    private let includesDiagnostics: Bool
    private var handler: (@MainActor @Sendable (TerminalKeyboardEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(
        center: NotificationCenter,
        includesDiagnostics: Bool
    ) {
        self.center = center
        self.includesDiagnostics = includesDiagnostics
    }

    func start(
        handler: @escaping @MainActor @Sendable (TerminalKeyboardEvent) -> Void
    ) {
        stop()
        self.handler = handler

        // UIKit can emit keyboard-frame notifications while SwiftUI is still
        // reconciling a scene transition. Delivery stays deferred by one main
        // queue turn, as it was before this platform adapter was extracted.
        for name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ] {
            observe(name, kind: .frameChanged)
        }
        observe(UIResponder.keyboardDidChangeFrameNotification, kind: .frameChanged)
        for name in [
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            observe(name, kind: .hidden)
        }
    }

    func stop() {
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        handler = nil
    }

    isolated deinit {
        stop()
    }

    private nonisolated enum NotificationKind: Sendable {
        case frameChanged
        case hidden
    }

    private func observe(
        _ name: Notification.Name,
        kind: NotificationKind
    ) {
        let observer = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // NotificationCenter guarantees this callback runs on the main queue.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated {
                self?.enqueue(notification, kind: kind)
            }
        }
        observers.append(observer)
    }

    private func enqueue(
        _ notification: Notification,
        kind: NotificationKind
    ) {
        let event = event(from: notification, kind: kind)
        Task { @MainActor [weak self] in
            self?.handler?(event)
        }
    }

    private func event(
        from notification: Notification,
        kind: NotificationKind
    ) -> TerminalKeyboardEvent {
        let beginFrame = frame(
            for: UIResponder.keyboardFrameBeginUserInfoKey,
            in: notification
        )
        let endFrame = frame(
            for: UIResponder.keyboardFrameEndUserInfoKey,
            in: notification
        )
        let curveRawValue = notification.userInfo?[
            UIResponder.keyboardAnimationCurveUserInfoKey
        ] as? Int
        let eventKind: TerminalKeyboardEvent.Kind = switch kind {
        case .frameChanged:
            .frameChanged(endFrame)
        case .hidden:
            .hidden
        }
        let diagnostics = includesDiagnostics
            ? TerminalKeyboardEvent.Diagnostics(
                name: notification.name.rawValue,
                object: String(describing: notification.object),
                beginFrame: beginFrame,
                endFrame: endFrame
            )
            : nil

        return TerminalKeyboardEvent(
            kind: eventKind,
            isLocal: (notification.userInfo?[
                UIResponder.keyboardIsLocalUserInfoKey
            ] as? NSNumber)?.boolValue,
            sourceScreenIdentifier: (notification.object as? UIScreen)
                .map(ObjectIdentifier.init),
            animationDuration: notification.userInfo?[
                UIResponder.keyboardAnimationDurationUserInfoKey
            ] as? TimeInterval,
            animationCurve: curveRawValue.flatMap(TerminalKeyboardAnimationCurve.init),
            diagnostics: diagnostics
        )
    }

    private func frame(
        for key: String,
        in notification: Notification
    ) -> CGRect? {
        (notification.userInfo?[key] as? NSValue)?.cgRectValue
    }
}

extension TerminalKeyboardCoordinator {
    convenience init(
        lifecycleLoggingEnabled: Bool = DebugLogConfiguration.isEnabled("keyboard")
    ) {
        self.init(
            keyboardEventSource: UIKitTerminalKeyboardEventSource(
                center: .default,
                includesDiagnostics: lifecycleLoggingEnabled
            ),
            lifecycleLoggingEnabled: lifecycleLoggingEnabled
        )
    }
}
#endif
