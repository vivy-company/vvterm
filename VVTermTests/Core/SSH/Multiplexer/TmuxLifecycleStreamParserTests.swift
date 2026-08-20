import Foundation
import Testing
@testable import VVTerm

struct TmuxLifecycleStreamParserTests {
    @Test
    func missingMarkerFallsBackToExistingTmuxSessionAsDetach() {
        let lifecycle = TmuxShellLifecycleContext(
            ownership: .managed,
            markerToken: "token",
            presenceProbe: .init(
                command: "probe",
                existsMarker: "exists",
                missingMarker: "missing"
            )
        )

        let reason = TerminalShellEndReason.resolve(
            tmuxLifecycle: lifecycle,
            markerEvent: nil,
            sessionExists: true
        )

        #expect(reason == .tmuxDetached(.managed))
    }

    @Test
    func missingMarkerFallsBackToMissingTmuxSessionAsEnd() {
        let lifecycle = TmuxShellLifecycleContext(
            ownership: .external,
            markerToken: "token",
            presenceProbe: .init(
                command: "probe",
                existsMarker: "exists",
                missingMarker: "missing"
            )
        )

        let reason = TerminalShellEndReason.resolve(
            tmuxLifecycle: lifecycle,
            markerEvent: nil,
            sessionExists: false
        )

        #expect(reason == .tmuxEnded(.external))
    }

    @Test
    func failedTmuxPresenceProbeRemainsTransportEnd() {
        let lifecycle = TmuxShellLifecycleContext(
            ownership: .managed,
            markerToken: "token",
            presenceProbe: .init(
                command: "probe",
                existsMarker: "exists",
                missingMarker: "missing"
            )
        )

        let reason = TerminalShellEndReason.resolve(
            tmuxLifecycle: lifecycle,
            markerEvent: nil,
            sessionExists: nil
        )

        #expect(reason == .transportEnded)
    }

    @Test
    func creationFailureIsNotReportedAsSessionEnd() {
        let lifecycle = TmuxShellLifecycleContext(
            ownership: .managed,
            markerToken: "token",
            presenceProbe: .init(
                command: "probe",
                existsMarker: "exists",
                missingMarker: "missing"
            )
        )

        let reason = TerminalShellEndReason.resolve(
            tmuxLifecycle: lifecycle,
            markerEvent: .creationFailed,
            sessionExists: false
        )

        #expect(reason == .tmuxCreationFailed)
    }

    @Test
    func presenceProbeParsesOnlyItsPrivateMarkers() {
        let probe = TmuxSessionPresenceProbe(
            command: "probe",
            existsMarker: "private-exists",
            missingMarker: "private-missing"
        )

        #expect(probe.sessionExists(in: "private-exists") == true)
        #expect(probe.sessionExists(in: "private-missing") == false)
        #expect(probe.sessionExists(in: "unrelated output") == nil)
    }

    @Test
    func removesDetachedMarkerAndReportsLifecycleEvent() {
        let token = "test-token"
        var parser = TmuxLifecycleStreamParser(markerToken: token)
        let input = Data("before\(TmuxLifecycleMarker.sequence(token: token, event: .detached))after".utf8)

        let result = parser.consume(input)

        #expect(String(decoding: result.output, as: UTF8.self) == "beforeafter")
        #expect(result.events == [.detached])
        #expect(parser.finish().isEmpty)
    }

    @Test
    func removesEndedMarkerSplitAcrossChunks() {
        let token = "split-token"
        var parser = TmuxLifecycleStreamParser(markerToken: token)
        let marker = Data(TmuxLifecycleMarker.sequence(token: token, event: .ended).utf8)
        let splitIndex = marker.index(marker.startIndex, offsetBy: marker.count / 2)

        let first = parser.consume(Data("visible".utf8) + marker[..<splitIndex])
        let second = parser.consume(marker[splitIndex...] + Data("tail".utf8))

        #expect(String(decoding: first.output, as: UTF8.self) == "visible")
        #expect(first.events.isEmpty)
        #expect(String(decoding: second.output, as: UTF8.self) == "tail")
        #expect(second.events == [.ended])
        #expect(parser.finish().isEmpty)
    }

    @Test
    func removesCreationFailedMarkerAndReportsLifecycleEvent() {
        let token = "failure-token"
        var parser = TmuxLifecycleStreamParser(markerToken: token)
        let marker = TmuxLifecycleMarker.sequence(token: token, event: .creationFailed)

        let result = parser.consume(Data("error\(marker)".utf8))

        #expect(String(decoding: result.output, as: UTF8.self) == "error")
        #expect(result.events == [.creationFailed])
        #expect(parser.finish().isEmpty)
    }

    @Test
    func preservesMarkerForDifferentConnectionToken() {
        var parser = TmuxLifecycleStreamParser(markerToken: "expected")
        let otherMarker = TmuxLifecycleMarker.sequence(token: "other", event: .detached)

        let result = parser.consume(Data(otherMarker.utf8))
        let remaining = parser.finish()

        #expect(String(decoding: result.output + remaining, as: UTF8.self) == otherMarker)
        #expect(result.events.isEmpty)
    }

    @Test
    func finishReturnsIncompleteMarkerPrefixAsNormalOutput() {
        let token = "partial-token"
        var parser = TmuxLifecycleStreamParser(markerToken: token)
        let marker = TmuxLifecycleMarker.sequence(token: token, event: .detached)
        let prefix = String(marker.prefix(marker.count - 4))

        let result = parser.consume(Data(prefix.utf8))
        let remaining = parser.finish()

        #expect(result.output.isEmpty)
        #expect(String(decoding: remaining, as: UTF8.self) == prefix)
        #expect(result.events.isEmpty)
    }
}
