import CloudKit
import Foundation
import os.log

@MainActor
final class TerminalAccessoryCloudKitClient: TerminalAccessoryCloudClient {
    static let maximumConflictAttempts = 4

    private let transport: any CloudKitRecordTransport
    private let logger = Logger(
        subsystem: "app.vivy.VVTerm",
        category: "TerminalAccessoryCloudKit"
    )

    init(transport: any CloudKitRecordTransport) {
        self.transport = transport
    }

    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        try await transport.performCloudKitRecordMutation { [self] in
            try await synchronize(localProfile.normalized())
        }
    }

    private func synchronize(
        _ normalizedLocal: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        let recordID = TerminalAccessoryCloudKitRecordCodec.recordID(
            in: transport.cloudKitRecordZoneID
        )
        var baseRecord: CKRecord?
        var mergedProfile = normalizedLocal

        do {
            let remoteRecord = try await transport.fetchCloudKitRecord(recordID)
            baseRecord = remoteRecord
            if let remoteProfile = TerminalAccessoryCloudKitRecordCodec.profile(
                from: remoteRecord
            ) {
                let normalizedRemote = remoteProfile.normalized()
                mergedProfile = TerminalAccessoryCloudKitRecordCodec.merge(
                    local: normalizedLocal,
                    remote: normalizedRemote
                )
                if mergedProfile == normalizedRemote {
                    return normalizedRemote
                }
            } else {
                logger.warning(
                    "Terminal accessory remote payload was invalid; keeping local profile"
                )
            }
        } catch {
            guard transport.isCloudKitRecordMissing(error) else { throw error }
        }

        for _ in 0..<Self.maximumConflictAttempts {
            let candidateRecord = try TerminalAccessoryCloudKitRecordCodec.record(
                for: mergedProfile,
                recordID: recordID,
                existingRecord: baseRecord
            )

            do {
                try await transport.saveCloudKitRecordIfUnchanged(candidateRecord)
                return mergedProfile
            } catch {
                if let serverRecord = transport.cloudKitServerRecord(from: error),
                   let serverProfile = TerminalAccessoryCloudKitRecordCodec.profile(
                       from: serverRecord
                   ) {
                    let normalizedRemote = serverProfile.normalized()
                    let conflictResolved = TerminalAccessoryCloudKitRecordCodec.merge(
                        local: mergedProfile,
                        remote: normalizedRemote
                    )
                    if conflictResolved == normalizedRemote {
                        return normalizedRemote
                    }
                    mergedProfile = conflictResolved
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

        throw TerminalAccessoryCloudClientError.conflictRetryLimitReached
    }
}
