#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import VVTerm

@MainActor
private final class TerminalKeyboardEventSourceSpy: TerminalKeyboardEventSource {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var handler: (@MainActor @Sendable (TerminalKeyboardEvent) -> Void)?

    func start(
        handler: @escaping @MainActor @Sendable (TerminalKeyboardEvent) -> Void
    ) {
        startCallCount += 1
        self.handler = handler
    }

    func stop() {
        stopCallCount += 1
        handler = nil
    }

    func send(_ event: TerminalKeyboardEvent) {
        handler?(event)
    }
}

private final class TerminalKeyboardWeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
struct TerminalKeyboardEventSourceTests {
    @Test
    func coordinatorStartsAndStopsItsInjectedSource() {
        let source = TerminalKeyboardEventSourceSpy()
        var coordinator: TerminalKeyboardCoordinator? = TerminalKeyboardCoordinator(
            keyboardEventSource: source,
            lifecycleLoggingEnabled: false
        )
        let weakCoordinator = TerminalKeyboardWeakBox(coordinator!)

        #expect(source.startCallCount == 1)

        coordinator = nil

        #expect(weakCoordinator.value == nil)
        #expect(source.stopCallCount == 1)
    }

    @Test
    func coordinatorAppliesSemanticAnimationValues() {
        let source = TerminalKeyboardEventSourceSpy()
        let coordinator = TerminalKeyboardCoordinator(
            keyboardEventSource: source,
            lifecycleLoggingEnabled: false
        )

        source.send(TerminalKeyboardEvent(
            kind: .hidden,
            isLocal: true,
            sourceScreenIdentifier: nil,
            animationDuration: 0.4,
            animationCurve: .linear,
            diagnostics: nil
        ))

        #expect(coordinator.keyboardAnimationDuration == 0.4)
        #expect(coordinator.keyboardAnimationCurve == .linear)
    }

    @Test
    func UIKitSourceMapsFrameNotificationAndStopsDelivery() async {
        let center = NotificationCenter()
        let source = UIKitTerminalKeyboardEventSource(
            center: center,
            includesDiagnostics: true
        )
        var events: [TerminalKeyboardEvent] = []
        source.start { event in
            events.append(event)
        }
        let beginFrame = CGRect(x: 0, y: 900, width: 800, height: 300)
        let endFrame = CGRect(x: 0, y: 700, width: 800, height: 300)

        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: beginFrame),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: endFrame),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
                UIResponder.keyboardAnimationCurveUserInfoKey: UIView.AnimationCurve.easeOut.rawValue,
                UIResponder.keyboardIsLocalUserInfoKey: true,
            ]
        )
        await waitUntil { events.count == 1 }

        #expect(events == [TerminalKeyboardEvent(
            kind: .frameChanged(endFrame),
            isLocal: true,
            sourceScreenIdentifier: nil,
            animationDuration: 0.25,
            animationCurve: .easeOut,
            diagnostics: TerminalKeyboardEvent.Diagnostics(
                name: UIResponder.keyboardWillChangeFrameNotification.rawValue,
                object: "nil",
                beginFrame: beginFrame,
                endFrame: endFrame
            )
        )])

        source.stop()
        center.post(
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(events.count == 1)
    }

    @Test
    func UIKitSourceReleaseRemovesObserversAndPendingDelivery() async {
        let center = NotificationCenter()
        var events: [TerminalKeyboardEvent] = []
        var source: UIKitTerminalKeyboardEventSource? = UIKitTerminalKeyboardEventSource(
            center: center,
            includesDiagnostics: false
        )
        let weakSource = TerminalKeyboardWeakBox(source!)
        source?.start { event in
            events.append(event)
        }

        source = nil
        center.post(
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(weakSource.value == nil)
        #expect(events.isEmpty)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for a semantic keyboard event")
    }
}
#endif
