import Foundation
import os.log

@MainActor
final class TerminalThemeCloudKitClient: TerminalThemeCloudClient,
    TerminalThemeCloudMutationClient {
    private let transport: any CloudKitRecordTransport
    private let logger = Logger(
        subsystem: "app.vivy.VVTerm",
        category: "TerminalThemeCloudKit"
    )

    init(transport: any CloudKitRecordTransport) {
        self.transport = transport
    }

    func fetchTerminalThemes() async throws -> [TerminalTheme] {
        let records = try await transport.fetchCloudKitRecords(
            matchingRecordTypes: [TerminalThemeCloudKitRecordCodec.recordType],
            desiredKeys: TerminalThemeCloudKitRecordCodec.recordKeys
        )
        let themes = records.compactMap(TerminalThemeCloudKitRecordCodec.theme(from:))
        let invalidRecordCount = records.count - themes.count
        if invalidRecordCount > 0 {
            logger.warning(
                "Ignored \(invalidRecordCount) invalid terminal theme CloudKit records"
            )
        }
        return themes
    }

    func fetchTerminalThemePreference() async throws -> TerminalThemePreference? {
        let recordID = TerminalThemePreferenceCloudKitRecordCodec.recordID(
            in: transport.cloudKitRecordZoneID
        )
        do {
            let record = try await transport.fetchCloudKitRecord(recordID)
            guard let preference = TerminalThemePreferenceCloudKitRecordCodec.preference(
                from: record
            ) else {
                logger.warning("Ignored invalid terminal theme preference CloudKit record")
                return nil
            }
            return preference
        } catch {
            guard transport.isCloudKitRecordMissing(error) else { throw error }
            return nil
        }
    }

    func saveTerminalTheme(_ theme: TerminalTheme) async throws {
        let record = TerminalThemeCloudKitRecordCodec.record(
            for: theme,
            in: transport.cloudKitRecordZoneID
        )
        do {
            try await transport.performCloudKitRecordMutation { [transport] in
                try await transport.upsertCloudKitRecord(record)
            }
            logger.info("Saved terminal theme \(theme.name) to CloudKit")
        } catch {
            logger.error("Failed to save terminal theme: \(error.localizedDescription)")
            throw error
        }
    }

    func saveTerminalThemePreference(
        _ preference: TerminalThemePreference
    ) async throws {
        let record = TerminalThemePreferenceCloudKitRecordCodec.record(
            for: preference,
            in: transport.cloudKitRecordZoneID
        )
        do {
            try await transport.performCloudKitRecordMutation { [transport] in
                try await transport.upsertCloudKitRecord(record)
            }
            logger.info("Saved terminal theme preference to CloudKit")
        } catch {
            logger.error(
                "Failed to save terminal theme preference: \(error.localizedDescription)"
            )
            throw error
        }
    }
}
