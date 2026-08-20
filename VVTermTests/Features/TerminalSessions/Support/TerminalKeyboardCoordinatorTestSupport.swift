#if os(iOS)
import Combine
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

@MainActor
final class TerminalKeyboardInputSessionSpy: TerminalKeyboardInputSession {
    var snapshot = TerminalKeyboardCoordinatorDiagnosticSnapshot(
        windowAttached: true,
        windowIsKey: true,
        sceneActivationState: "foregroundActive",
        isFirstResponder: true,
        isSoftwareInputActive: true
    )
    private(set) var acquireCount = 0
    private(set) var forceSoftwareKeyboardCount = 0
    private(set) var focusWithoutSoftwareKeyboardCount = 0
    private(set) var releaseCount = 0
    private(set) var rebuildCount = 0
    private(set) var accessorySuppressionRequests: [Bool] = []
    private(set) var accessoryReloadCount = 0
    private(set) var accessoryAppearanceRefreshCount = 0
    var acquireResults: [Bool] = []
    var acquireObservedStates: [Bool] = []
    var forceSoftwareKeyboardResults: [Bool] = []
    var forceSoftwareKeyboardObservedStates: [Bool] = []
    var completesRebuildImmediately = true
    var onAcquire: (() -> Void)?
    private var pendingRebuildCompletions: [() -> Void] = []

    func keyboardCoordinatorDiagnosticSnapshot() -> TerminalKeyboardCoordinatorDiagnosticSnapshot {
        snapshot
    }

    func acquireTerminalInput() -> Bool {
        acquireCount += 1
        onAcquire?()
        let result = acquireResults.isEmpty ? true : acquireResults.removeFirst()
        let observed = acquireObservedStates.isEmpty ? result : acquireObservedStates.removeFirst()
        snapshot.isFirstResponder = observed
        snapshot.isSoftwareInputActive = observed
        if observed {
            snapshot.isKeyboardInBrowseMode = false
        }
        return result
    }

    func forceSoftwareKeyboardInput() -> Bool {
        forceSoftwareKeyboardCount += 1
        let result = forceSoftwareKeyboardResults.isEmpty
            ? true
            : forceSoftwareKeyboardResults.removeFirst()
        let observed = forceSoftwareKeyboardObservedStates.isEmpty
            ? result
            : forceSoftwareKeyboardObservedStates.removeFirst()
        snapshot.isFirstResponder = observed
        snapshot.isSoftwareInputActive = observed
        if observed {
            snapshot.isKeyboardInBrowseMode = false
        }
        return result
    }

    func focusTerminalInputWithoutShowingSoftwareKeyboard() -> Bool {
        focusWithoutSoftwareKeyboardCount += 1
        snapshot.isFirstResponder = true
        snapshot.isSoftwareInputActive = true
        snapshot.isSoftwareKeyboardSuppressed = true
        snapshot.isKeyboardInBrowseMode = true
        return true
    }

    func releaseTerminalInput() {
        releaseCount += 1
        snapshot.isFirstResponder = false
        snapshot.isSoftwareInputActive = false
    }

    func releaseTerminalInputForReacquisition(completion: @escaping () -> Void) {
        rebuildCount += 1
        releaseTerminalInput()
        if completesRebuildImmediately {
            completion()
        } else {
            pendingRebuildCompletions.append(completion)
        }
    }

    func setTerminalInputAccessorySuppressed(_ suppressed: Bool) {
        accessorySuppressionRequests.append(suppressed)
        let wasEffectivelySuppressed = snapshot.isSoftwareKeyboardSuppressed
            || snapshotAccessorySuppressed
        if snapshotAccessorySuppressed != suppressed {
            snapshotAccessorySuppressed = suppressed
        }
        let isEffectivelySuppressed = snapshot.isSoftwareKeyboardSuppressed
            || snapshotAccessorySuppressed
        if wasEffectivelySuppressed != isEffectivelySuppressed {
            accessoryReloadCount += 1
        }
    }

    func refreshTerminalInputAccessoryAppearance() {
        accessoryAppearanceRefreshCount += 1
    }

    func resetCommands() {
        acquireCount = 0
        forceSoftwareKeyboardCount = 0
        focusWithoutSoftwareKeyboardCount = 0
        releaseCount = 0
        rebuildCount = 0
        accessorySuppressionRequests.removeAll()
        accessoryReloadCount = 0
        accessoryAppearanceRefreshCount = 0
    }

    func completeNextRebuild() {
        guard !pendingRebuildCompletions.isEmpty else { return }
        pendingRebuildCompletions.removeFirst()()
    }

    private var snapshotAccessorySuppressed = false
}

@MainActor
final class TerminalKeyboardCoordinatorEventSourceSpy: TerminalKeyboardEventSource {
    private var handler: (@MainActor @Sendable (TerminalKeyboardEvent) -> Void)?

    func start(
        handler: @escaping @MainActor @Sendable (TerminalKeyboardEvent) -> Void
    ) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func send(_ kind: TerminalKeyboardEvent.Kind) {
        handler?(
            TerminalKeyboardEvent(
                kind: kind,
                isLocal: true,
                sourceScreenIdentifier: nil,
                animationDuration: nil,
                animationCurve: nil,
                diagnostics: nil
            )
        )
    }
}
@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
func waitForMainActorCondition(
    _ condition: () -> Bool
) async {
    for _ in 0..<100 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await drainMainQueue()
    }
}
#endif
