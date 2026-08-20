import XCTest
@testable import VVTerm

final class ServerStatsDomainTests: XCTestCase {
    func testCollectionFailureRemainsObservable() {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()

        state.start(attemptID: attemptID)
        XCTAssertTrue(state.markConnected(attemptID: attemptID))
        XCTAssertTrue(
            state.finish(
                attemptID: attemptID,
                failure: .external(detail: "Connection failed")
            )
        )

        XCTAssertEqual(state.phase, .failed(.external(detail: "Connection failed")))
        XCTAssertFalse(state.isCollecting)
    }

    func testStaleCollectionCompletionCannotFinishNewAttempt() {
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        var state = ServerStatsCollectionState()

        state.start(attemptID: firstAttemptID)
        state.stop()
        state.start(attemptID: secondAttemptID)

        XCTAssertFalse(
            state.finish(
                attemptID: firstAttemptID,
                failure: .external(detail: "Stale failure")
            )
        )
        XCTAssertEqual(state.phase, .starting(attemptID: secondAttemptID))
        XCTAssertTrue(state.isCollecting)
    }

    func testStaleCollectionConnectionCannotAdvanceNewAttempt() {
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        var state = ServerStatsCollectionState()

        state.start(attemptID: firstAttemptID)
        state.stop()
        state.start(attemptID: secondAttemptID)

        XCTAssertFalse(state.markConnected(attemptID: firstAttemptID))
        XCTAssertEqual(state.phase, .starting(attemptID: secondAttemptID))
    }

    func testPauseAndResumePreserveStartingAttempt() {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()

        state.start(attemptID: attemptID)

        XCTAssertTrue(state.pause(attemptID: attemptID))
        XCTAssertEqual(state.phase, .startingPaused(attemptID: attemptID))
        XCTAssertFalse(state.isCollecting)

        XCTAssertTrue(state.resume(attemptID: attemptID))
        XCTAssertEqual(state.phase, .starting(attemptID: attemptID))
        XCTAssertTrue(state.isCollecting)
    }

    func testConnectedAttemptCanPauseAndResumeWithoutChangingIdentity() {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()

        state.start(attemptID: attemptID)
        XCTAssertTrue(state.markConnected(attemptID: attemptID))

        XCTAssertTrue(state.pause(attemptID: attemptID))
        XCTAssertEqual(state.phase, .paused(attemptID: attemptID))
        XCTAssertFalse(state.isCollecting)

        XCTAssertTrue(state.resume(attemptID: attemptID))
        XCTAssertEqual(state.phase, .collecting(attemptID: attemptID))
        XCTAssertTrue(state.isCollecting)
    }

    func testConnectionCompletionWhilePausedKeepsAttemptPaused() {
        let attemptID = UUID()
        var state = ServerStatsCollectionState()

        state.start(attemptID: attemptID)
        XCTAssertTrue(state.pause(attemptID: attemptID))

        XCTAssertTrue(state.markConnected(attemptID: attemptID))
        XCTAssertEqual(state.phase, .paused(attemptID: attemptID))
        XCTAssertFalse(state.isCollecting)
    }

    func testStaleAttemptCannotPauseOrResumeCurrentAttempt() {
        let currentAttemptID = UUID()
        let staleAttemptID = UUID()
        var state = ServerStatsCollectionState()

        state.start(attemptID: currentAttemptID)
        XCTAssertFalse(state.pause(attemptID: staleAttemptID))
        XCTAssertEqual(state.phase, .starting(attemptID: currentAttemptID))

        XCTAssertTrue(state.pause(attemptID: currentAttemptID))
        XCTAssertFalse(state.resume(attemptID: staleAttemptID))
        XCTAssertEqual(state.phase, .startingPaused(attemptID: currentAttemptID))
    }

    func testHostKeyApprovalRemainsTyped() {
        let attemptID = UUID()
        let serverID = UUID()
        let request = ServerStatsApprovalRequest(
            id: "host-key:\(serverID.uuidString)",
            serverID: serverID
        )
        var state = ServerStatsCollectionState()

        state.start(attemptID: attemptID)

        XCTAssertTrue(state.requireApproval(attemptID: attemptID, request: request))
        XCTAssertEqual(state.approvalRequest, request)
    }

    func testApprovalCancellationBecomesClearFailure() {
        let attemptID = UUID()
        let request = ServerStatsApprovalRequest(
            id: "host-key",
            serverID: UUID()
        )
        var state = ServerStatsCollectionState()
        state.start(attemptID: attemptID)
        XCTAssertTrue(state.requireApproval(attemptID: attemptID, request: request))

        XCTAssertTrue(
            state.resolveApproval(
                request,
                failure: .securityApprovalCancelled
            )
        )
        XCTAssertNil(state.approvalRequest)
        XCTAssertEqual(state.phase, .failed(.securityApprovalCancelled))
    }

    func testMemoryPercentReturnsZeroWhenTotalIsZero() {
        var stats = ServerStats()
        stats.memoryUsed = 512
        stats.memoryTotal = 0

        XCTAssertEqual(stats.memoryPercent, 0)
    }

    func testMemoryPercentUsesUsedAndTotalBytes() {
        var stats = ServerStats()
        stats.memoryUsed = 512
        stats.memoryTotal = 1024

        XCTAssertEqual(stats.memoryPercent, 50, accuracy: 0.001)
    }

    func testVolumePercentReturnsZeroWhenTotalIsZero() {
        let volume = VolumeInfo(mountPoint: "/", used: 100, total: 0)

        XCTAssertEqual(volume.percent, 0)
    }

    func testVolumePercentCalculatesUsage() {
        let volume = VolumeInfo(mountPoint: "/", used: 25, total: 100)

        XCTAssertEqual(volume.percent, 25, accuracy: 0.001)
    }

    func testArrayMemberKeepsTopologyWarningWhenDeviceProbeIsUnavailable() {
        let member = StorageHealthMemberReport(
            id: StorageDeviceIdentity(namespace: "test", opaqueValue: "member"),
            role: .data,
            ordinal: 1,
            result: .unavailable(.permissionDenied),
            findings: [StorageHealthFinding(
                kind: .deviceErrors(read: 1, write: 0, checksum: 0),
                severity: .warning,
                source: .zfs
            )]
        )
        let volume = StorageHealthVolumeReport(
            topology: .zfs,
            name: "tank",
            coverage: .partial,
            findings: [],
            members: [member]
        )

        XCTAssertEqual(member.state, .warning)
        XCTAssertEqual(volume.state, .warning)
    }

    func testRemotePlatformDetectsWindowsMarkers() {
        XCTAssertEqual(RemotePlatform.detect(from: "MINGW64_NT-10.0"), .windows)
        XCTAssertEqual(RemotePlatform.detect(from: "Windows_NT"), .windows)
    }

    func testRemotePlatformDefaultsUnknownUnixLikeOutputToLinux() {
        XCTAssertEqual(RemotePlatform.detect(from: "Solaris"), .linux)
    }

    func testResolvedCPUCoreCountAllowsLiveCountToReplaceFallbackOne() {
        XCTAssertEqual(ServerStatsCollector.resolvedCPUCoreCount(existing: 1, collected: 10), 10)
    }

    func testResolvedCPUCoreCountKeepsExistingWhenLiveCountMissing() {
        XCTAssertEqual(ServerStatsCollector.resolvedCPUCoreCount(existing: 10, collected: 0), 10)
    }

    func testResolvedCPUCoreCountUsesCollectedWhenNoExistingCount() {
        XCTAssertEqual(ServerStatsCollector.resolvedCPUCoreCount(existing: 0, collected: 8), 8)
    }

    func testStatsPreferencesDefaultStyleIsCardsDetailed() {
        XCTAssertEqual(
            StatsPreferences.defaultValue(lastWriterDeviceId: "test").style,
            .cardsDetailed
        )
    }

    func testStatsPreferencesDefaultBlocksIncludeDockerVisible() {
        let preferences = StatsPreferences.defaultValue(lastWriterDeviceId: "test")
        XCTAssertTrue(preferences.visibleBlocks.contains(.docker))
        XCTAssertTrue(preferences.isBlockVisible(.docker))
    }

    func testStatsPreferencesNormalizeDeduplicatesAndReindexesBlocks() {
        let olderCPUBlock = StatsPreferences.Block(
            id: .cpu,
            isVisible: true,
            order: 4,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let newerCPUBlock = StatsPreferences.Block(
            id: .cpu,
            isVisible: false,
            order: 1,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let preferences = StatsPreferences(
            style: .cardsCompact,
            blocks: [
                StatsPreferences.Block(id: .network, isVisible: true, order: 0, updatedAt: Date(timeIntervalSince1970: 1)),
                olderCPUBlock,
                newerCPUBlock
            ],
            updatedAt: Date(timeIntervalSince1970: 3),
            lastWriterDeviceId: "test"
        )

        let normalized = preferences.normalized()

        XCTAssertEqual(Set(normalized.blocks.map(\.id)), Set(StatsPreferences.BlockID.allCases))
        XCTAssertEqual(normalized.blocks.map(\.order), Array(0..<StatsPreferences.BlockID.allCases.count))
        XCTAssertEqual(normalized.blocks.first(where: { $0.id == .cpu })?.isVisible, false)
    }

    func testStatsPreferencesNormalizeKeepsSystemVisible() {
        let preferences = StatsPreferences(
            style: .cardsCompact,
            blocks: [
                StatsPreferences.Block(id: .system, isVisible: false, order: 0, updatedAt: Date(timeIntervalSince1970: 2)),
                StatsPreferences.Block(id: .cpu, isVisible: true, order: 1, updatedAt: Date(timeIntervalSince1970: 2))
            ],
            updatedAt: Date(timeIntervalSince1970: 2),
            lastWriterDeviceId: "test"
        )

        let normalized = preferences.normalized()

        XCTAssertTrue(normalized.isBlockVisible(.system))
        XCTAssertTrue(normalized.visibleBlocks.contains(.system))
    }

    func testStatsPreferencesMergeUsesBlockTimestampsForVisibilityAndProfileTimestampForStyleAndOrder() {
        let local = makeStatsPreferences(
            style: .cardsCompact,
            updatedAt: Date(timeIntervalSince1970: 10),
            blocks: [
                makeStatsBlock(.system, isVisible: true, order: 0, updatedAt: 1),
                makeStatsBlock(.cpu, isVisible: false, order: 1, updatedAt: 9),
                makeStatsBlock(.network, isVisible: true, order: 2, updatedAt: 1)
            ]
        )
        let remote = makeStatsPreferences(
            style: .cardsDetailed,
            updatedAt: Date(timeIntervalSince1970: 20),
            blocks: [
                makeStatsBlock(.network, isVisible: true, order: 0, updatedAt: 20),
                makeStatsBlock(.system, isVisible: true, order: 1, updatedAt: 1),
                makeStatsBlock(.cpu, isVisible: true, order: 2, updatedAt: 1)
            ]
        )

        let merged = StatsPreferences.merged(local: local, remote: remote)

        XCTAssertEqual(merged.style, .cardsDetailed)
        XCTAssertEqual(Array(merged.visibleBlocks.prefix(2)), [.network, .system])
        XCTAssertFalse(merged.isBlockVisible(.cpu))
    }

    func testStatsPreferencesMergePrefersRemoteOnExactProfileTimestampTie() {
        let timestamp = Date(timeIntervalSince1970: 1)
        let local = StatsPreferences(
            style: .cardsCompact,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: timestamp,
            lastWriterDeviceId: "local"
        )
        let remote = StatsPreferences(
            style: .cardsCompact,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: timestamp,
            lastWriterDeviceId: "remote"
        )

        let merged = StatsPreferences.merged(local: local, remote: remote)

        XCTAssertEqual(merged.lastWriterDeviceId, "remote")
    }

    private func makeStatsPreferences(
        style: StatsPreferences.Style,
        updatedAt: Date,
        blocks: [StatsPreferences.Block]
    ) -> StatsPreferences {
        StatsPreferences(
            style: style,
            blocks: blocks,
            updatedAt: updatedAt,
            lastWriterDeviceId: "test"
        )
    }

    private func makeStatsBlock(
        _ id: StatsPreferences.BlockID,
        isVisible: Bool,
        order: Int,
        updatedAt: TimeInterval
    ) -> StatsPreferences.Block {
        StatsPreferences.Block(
            id: id,
            isVisible: isVisible,
            order: order,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
