import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyRuntimeStateTests {
    @Test
    func deferredRuntimeStartsIdle() {
        let runtime = GhosttyRuntime(autoStart: false)
        defer { runtime.cleanup() }

        #expect(runtime.app == nil)
        #expect(runtime.readiness == .idle)
    }

    @Test
    func startedRuntimeIsReadyAndSecondStartIsIdempotent() throws {
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        let initialApp = try #require(runtime.app)

        #expect(runtime.readiness == .ready)

        runtime.startIfNeeded()

        #expect(runtime.app == initialApp)
        #expect(runtime.readiness == .ready)
    }

    @Test
    func cleanupStopsRuntimeWithoutAllowingRestart() throws {
        let runtime = GhosttyRuntime()
        _ = try #require(runtime.app)

        runtime.cleanup()

        #expect(runtime.app == nil)
        #expect(runtime.readiness == .stopped)

        runtime.startIfNeeded()

        #expect(runtime.app == nil)
        #expect(runtime.readiness == .stopped)
    }
}
