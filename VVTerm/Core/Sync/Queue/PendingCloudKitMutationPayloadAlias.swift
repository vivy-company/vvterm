import Foundation

typealias PendingCloudKitMutationPayload = PendingCloudKitPayloadEnvelope

nonisolated protocol PendingCloudKitLegacyMutationMigrating {
    func migrate(
        recordData: Data
    ) -> Result<PendingCloudKitMutation, PendingCloudKitMutationQuarantineReason>?
}
