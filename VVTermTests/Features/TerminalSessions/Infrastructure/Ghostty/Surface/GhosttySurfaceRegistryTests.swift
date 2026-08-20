import CoreGraphics
import Foundation
import Testing
#if os(iOS)
import UIKit
#endif
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttySurfaceRegistryTests {
    @Test
    func repeatedTerminalCleanupRemovesSurfaceFromRegistryOnce() throws {
        let app = GhosttyRuntime()
        let appHandle = try #require(app.app)
        let terminal: GhosttyTerminalView
        #if os(iOS)
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "surface-registry",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "surface-registry-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "surface-registry",
            useCustomIO: true
        )
        #endif
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let surfaceWrapper = try #require(terminal.surface)
        let surface = try #require(surfaceWrapper.unsafeCValue)
        let callbackContext = surfaceWrapper.callbackContext
        let surfaceUserdata = try #require(ghostty_surface_userdata(surface))
        terminal.onZoomAction = { _ in nil }
        #if os(iOS)
        terminal.onKeyboardAvoidanceAccessoryFrameChange = { }
        terminal.onVoiceButtonTapped = { }
        terminal.onKeyboardBrowseModeChange = { _ in }
        let nativeTextInteraction = try #require(terminal.nativeTextInteraction)
        let nativeFindInteraction = try #require(terminal.nativeFindInteraction)
        #endif
        #expect(app.activeSurfaceCount() == 1)
        #expect(app.terminalView(for: surface) === terminal)
        #expect(surfaceUserdata == callbackContext.userdata)
        #expect(Ghostty.CallbackContext<GhosttyTerminalView>.resolve(surfaceUserdata) === terminal)

        terminal.cleanup()
        terminal.cleanup()

        #expect(app.activeSurfaceCount() == 0)
        #expect(app.terminalView(for: surface) == nil)
        #expect(callbackContext.resolve() == nil)
        #expect(surfaceWrapper.unsafeCValue == nil)
        #expect(terminal.onZoomAction == nil)
        #if os(iOS)
        #expect(terminal.onKeyboardAvoidanceAccessoryFrameChange == nil)
        #expect(terminal.onVoiceButtonTapped == nil)
        #expect(terminal.onKeyboardBrowseModeChange == nil)
        #expect(terminal.nativeTextInteraction == nil)
        #expect(terminal.nativeFindInteraction == nil)
        #expect(nativeTextInteraction.view == nil)
        #expect(nativeFindInteraction.view == nil)
        #else
        #expect(terminal.appearanceObservation == nil)
        #endif
    }

    @Test
    func nativeSurfaceReleaseLetsDeinitFinishTerminalTeardown() async throws {
        let app = GhosttyRuntime()
        let appHandle = try #require(app.app)
        let probe = try makeTerminalReleaseProbe(app: app, appHandle: appHandle)
        defer {
            probe.terminal.value?.cleanup()
            app.cleanup()
        }

        // libghostty keeps its platform view alive for the native surface lifetime.
        // Explicit terminal cleanup is the normal owner. This test releases that
        // native owner directly to prove deinit completes all remaining teardown.
        probe.surfaceWrapper.free()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(probe.terminal.value == nil)
        #expect(probe.surfaceWrapper.unsafeCValue == nil)
        #expect(probe.callbackContext.resolve() == nil)
        #expect(app.activeSurfaceCount() == 0)
        #expect(app.terminalView(for: probe.surface) == nil)
    }

    private func makeTerminalReleaseProbe(
        app: GhosttyRuntime,
        appHandle: ghostty_app_t
    ) throws -> TerminalReleaseProbe {
        let terminal: GhosttyTerminalView
        #if os(iOS)
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "surface-release",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "surface-release-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "surface-release",
            useCustomIO: true
        )
        #endif

        guard let surfaceWrapper = terminal.surface,
              let surface = surfaceWrapper.unsafeCValue else {
            terminal.cleanup()
            throw TerminalReleaseProbeError.surfaceUnavailable
        }
        let callbackContext = surfaceWrapper.callbackContext

        return TerminalReleaseProbe(
            surfaceWrapper: surfaceWrapper,
            surface: surface,
            callbackContext: callbackContext,
            terminal: WeakTerminalReference(terminal)
        )
    }

    @Test
    func surfaceReferenceWithoutTerminalViewIsPrunedFromRegistry() throws {
        let app = GhosttyRuntime()
        let appHandle = try #require(app.app)
        var terminal: GhosttyTerminalView?
        #if os(iOS)
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            paneId: "released-surface-registry",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "released-surface-registry-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        #else
        terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: appHandle,
            paneId: "released-surface-registry",
            useCustomIO: true
        )
        #endif
        let registryToken = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            terminal?.cleanup()
            app.cleanup()
            registryToken.deallocate()
        }

        let registeredTerminal = try #require(terminal)
        registeredTerminal.cleanup()
        let surfaceReference = app.registerSurface(
            registryToken,
            terminalView: registeredTerminal
        )

        #expect(app.activeSurfaceCount() == 1)
        #expect(app.terminalView(for: registryToken) === registeredTerminal)

        surfaceReference.terminalView = nil

        #expect(app.activeSurfaceCount() == 0)
        #expect(app.terminalView(for: registryToken) == nil)
    }
}

private enum TerminalReleaseProbeError: Error {
    case surfaceUnavailable
}

private struct TerminalReleaseProbe {
    let surfaceWrapper: Ghostty.Surface
    let surface: ghostty_surface_t
    let callbackContext: Ghostty.CallbackContext<GhosttyTerminalView>
    let terminal: WeakTerminalReference
}

private final class WeakTerminalReference {
    weak var value: GhosttyTerminalView?

    init(_ value: GhosttyTerminalView) {
        self.value = value
    }
}
