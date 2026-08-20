import Foundation
import Testing
@testable import VVTerm

@MainActor
struct GhosttyTerminalSurfaceStoreTests {
    private final class Surface: TerminalSurface {
        #if os(iOS)
        private final class InputSession: TerminalKeyboardInputSession {
            func keyboardCoordinatorDiagnosticSnapshot() -> TerminalKeyboardCoordinatorDiagnosticSnapshot {
                TerminalKeyboardCoordinatorDiagnosticSnapshot(
                    windowAttached: false,
                    windowIsKey: false,
                    sceneActivationState: "unattached",
                    isFirstResponder: false,
                    isSoftwareInputActive: false
                )
            }
            func acquireTerminalInput() -> Bool { false }
            func forceSoftwareKeyboardInput() -> Bool { false }
            func focusTerminalInputWithoutShowingSoftwareKeyboard() -> Bool { false }
            func releaseTerminalInput() {}
            func releaseTerminalInputForReacquisition(completion: @escaping () -> Void) {
                completion()
            }
            func setTerminalInputAccessorySuppressed(_ suppressed: Bool) {}
            func refreshTerminalInputAccessoryAppearance() {}
        }

        private let inputSession = InputSession()
        #endif

        var terminalGeometry: TerminalSurfaceGeometry?
        var isHostingSceneActive: Bool?
        private(set) var receivedOutput: [Data] = []

        func receiveTerminalOutput(_ data: Data) {
            receivedOutput.append(data)
        }
        func applyPresentationOverrides(_ overrides: TerminalPresentationOverrides) {}
        func cleanup() {}
        func installRichPasteInterceptor(_ interceptor: @escaping () -> Bool) {}
        func pasteTextFromClipboard() {}
        func sendText(_ text: String) {}

        #if os(iOS)
        var keyboardInputSession: any TerminalKeyboardInputSession { inputSession }
        var isAttachedToWindow = false
        var acceptsTerminalInput = true
        var shouldRestoreKeyboardFocusOnReconnect = false
        var isFindNavigatorVisible = false

        func setLifecycleCallbacks(_ callbacks: TerminalSurfaceLifecycleCallbacks?) {}
        #endif
    }

    @Test
    func surfacePortCarriesSemanticGeometryAndOutput() throws {
        let store = GhosttyTerminalSurfaceStore()
        let paneId = UUID()
        let surface = Surface()
        surface.terminalGeometry = TerminalSurfaceGeometry(
            columns: 120,
            rows: 40,
            pixelSize: TerminalPixelSize(width: 1_920, height: 1_080)
        )
        store.register(surface, for: paneId)

        let registered = try #require(store.surface(for: paneId))
        registered.receiveTerminalOutput(Data("ready".utf8))

        #expect(registered.terminalGeometry == surface.terminalGeometry)
        #expect(surface.receivedOutput == [Data("ready".utf8)])
    }

    #if os(iOS)
    @Test
    func inactiveTerminalPausesRenderingUntilItBecomesVisibleAgain() {
        #expect(
            TerminalRenderingPolicy.transition(
                terminalIsActive: false,
                sceneIsActive: true,
                renderingIsPaused: false
            ) == .pause
        )
        #expect(
            TerminalRenderingPolicy.transition(
                terminalIsActive: true,
                sceneIsActive: true,
                renderingIsPaused: true
            ) == .resume
        )
    }
    #endif

    @Test
    func replacementPublishesTypedChangeAndKeepsStableIdentity() {
        let registry = GhosttyTerminalSurfaceStore()
        let paneId = UUID()
        let first = Surface()
        let replacement = Surface()
        let secondReplacement = Surface()

        #expect(!registry.register(first, for: paneId))
        #expect(registry.surface(for: paneId) === first)
        #expect(registry.latestChange == .registered(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(first)
        ))

        #expect(!registry.register(first, for: paneId))
        #expect(registry.latestChange == .registered(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(first)
        ))

        #expect(registry.register(replacement, for: paneId))
        #expect(registry.surface(for: paneId) === replacement)
        let firstReplacementChange = registry.latestChange
        #expect(firstReplacementChange == .replaced(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(replacement)
        ))

        #expect(registry.register(secondReplacement, for: paneId))
        #expect(registry.surface(for: paneId) === secondReplacement)
        #expect(registry.latestChange == .replaced(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(secondReplacement)
        ))
        #expect(registry.latestChange != firstReplacementChange)
    }

    @Test
    func staleTeardownCleansOnlyReporterAndPreservesReplacement() {
        let registry = GhosttyTerminalSurfaceStore()
        let paneId = UUID()
        let stale = Surface()
        let replacement = Surface()
        var cleaned: [ObjectIdentifier] = []
        registry.register(stale, for: paneId)
        registry.register(replacement, for: paneId)

        let removed = registry.unregister(
            stale,
            for: paneId,
            prepareForRemoval: { _ in },
            cleanup: { cleaned.append(ObjectIdentifier($0)) }
        )

        #expect(!removed)
        #expect(cleaned == [ObjectIdentifier(stale)])
        #expect(registry.surface(for: paneId) === replacement)
        #expect(registry.latestChange == .replaced(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(replacement)
        ))
    }

    @Test
    func twoRegistriesDoNotShareSurfacesOrChanges() {
        let firstRegistry = GhosttyTerminalSurfaceStore()
        let secondRegistry = GhosttyTerminalSurfaceStore()
        let paneId = UUID()
        let surface = Surface()

        firstRegistry.register(surface, for: paneId)

        #expect(firstRegistry.surface(for: paneId) === surface)
        #expect(secondRegistry.surface(for: paneId) == nil)
        #expect(firstRegistry.latestChange == .registered(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(surface)
        ))
        #expect(secondRegistry.latestChange == nil)
    }

    @Test
    func drainCleansEachRegisteredSurfaceExactlyOnce() {
        let registry = GhosttyTerminalSurfaceStore()
        let firstPaneId = UUID()
        let secondPaneId = UUID()
        let duplicatePaneId = UUID()
        let first = Surface()
        let second = Surface()
        var cleanupCounts: [ObjectIdentifier: Int] = [:]
        registry.register(first, for: firstPaneId)
        registry.register(second, for: secondPaneId)
        registry.register(first, for: duplicatePaneId)

        registry.drain(
            prepareForRemoval: { _, _ in },
            cleanup: { surface in
                cleanupCounts[ObjectIdentifier(surface), default: 0] += 1
            }
        )
        registry.drain(
            prepareForRemoval: { _, _ in },
            cleanup: { surface in
                cleanupCounts[ObjectIdentifier(surface), default: 0] += 1
            }
        )

        #expect(cleanupCounts[ObjectIdentifier(first)] == 1)
        #expect(cleanupCounts[ObjectIdentifier(second)] == 1)
        #expect(registry.surface(for: firstPaneId) == nil)
        #expect(registry.surface(for: secondPaneId) == nil)
        #expect(registry.surface(for: duplicatePaneId) == nil)
        #expect(registry.latestChange == .drained(
            surfaceIdentitiesByPane: [
                firstPaneId: ObjectIdentifier(first),
                secondPaneId: ObjectIdentifier(second),
                duplicatePaneId: ObjectIdentifier(first),
            ]
        ))
    }
}
