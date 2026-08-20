import CloudKit
import Foundation
import os.log

@MainActor
final class StatsPreferencesCloudKitClient: StatsPreferencesCloudClient {
    static let maximumConflictAttempts = 4

    private let transport: any CloudKitRecordTransport
    private let logger = Logger(
        subsystem: "app.vivy.VVTerm",
        category: "StatsPreferencesCloudKit"
    )

    init(transport: any CloudKitRecordTransport) {
        self.transport = transport
    }

    func syncStatsPreferences(
        _ localPreferences: StatsPreferences
    ) async throws -> StatsPreferences {
        try await transport.performCloudKitRecordMutation { [self] in
            try await synchronize(localPreferences.normalized())
        }
    }

    private func synchronize(
        _ normalizedLocal: StatsPreferences
    ) async throws -> StatsPreferences {
        let recordID = StatsPreferencesCloudKitRecordCodec.recordID(
            in: transport.cloudKitRecordZoneID
        )
        var baseRecord: CKRecord?
        var mergedPreferences = normalizedLocal

        do {
            let remoteRecord = try await transport.fetchCloudKitRecord(recordID)
            baseRecord = remoteRecord
            if let remotePreferences = StatsPreferencesCloudKitRecordCodec.preferences(
                from: remoteRecord
            ) {
                let normalizedRemote = remotePreferences.normalized()
                mergedPreferences = StatsPreferencesCloudKitRecordCodec.merge(
                    local: normalizedLocal,
                    remote: normalizedRemote
                )
                if mergedPreferences == normalizedRemote {
                    return normalizedRemote
                }
            } else {
                logger.warning(
                    "Stats preferences remote payload was invalid; keeping local preferences"
                )
            }
        } catch {
            guard transport.isCloudKitRecordMissing(error) else { throw error }
        }

        for _ in 0..<Self.maximumConflictAttempts {
            let candidateRecord = try StatsPreferencesCloudKitRecordCodec.record(
                for: mergedPreferences,
                recordID: recordID,
                existingRecord: baseRecord
            )

            do {
                try await transport.saveCloudKitRecordIfUnchanged(candidateRecord)
                return mergedPreferences
            } catch {
                if let serverRecord = transport.cloudKitServerRecord(from: error),
                   let serverPreferences = StatsPreferencesCloudKitRecordCodec.preferences(
                       from: serverRecord
                   ) {
                    let normalizedRemote = serverPreferences.normalized()
                    let conflictResolved = StatsPreferencesCloudKitRecordCodec.merge(
                        local: mergedPreferences,
                        remote: normalizedRemote
                    )
                    if conflictResolved == normalizedRemote {
                        return normalizedRemote
                    }
                    mergedPreferences = conflictResolved
                    baseRecord = serverRecord
                    continue
                }

                if transport.isCloudKitRecordMissing(error) {
                    baseRecord = nil
                    continue
                }

                throw error
            }
        }

        throw StatsPreferencesCloudClientError.conflictRetryLimitReached
    }
}
