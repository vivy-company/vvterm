import Foundation
import Testing
@testable import VVTerm

@Suite
struct GhosttyRuntimeCallbackIsolationTests {
    @Test
    @MainActor
    func nativeWakeupCallbackAcceptsRendererThreadInvocation() async {
        let runtimeConfiguration = GhosttyRuntime.makeRuntimeConfiguration(
            userdata: nil,
            supportsSelectionClipboard: false
        )
        let wakeup = runtimeConfiguration.wakeup_cb

        let ranOffMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                wakeup?(nil)
                continuation.resume(returning: !Thread.isMainThread)
            }
        }

        #expect(ranOffMainThread)
    }

    @Test
    @MainActor
    func nativeWriteCallbackAcceptsIOThreadInvocation() async {
        let ranOffMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                ghosttyTerminalWriteCallback(nil, nil, 0)
                continuation.resume(returning: !Thread.isMainThread)
            }
        }

        #expect(ranOffMainThread)
    }
}
