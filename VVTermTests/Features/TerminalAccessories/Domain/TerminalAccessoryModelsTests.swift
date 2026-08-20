import Foundation
import Testing
@testable import VVTerm

struct TerminalAccessoryModelsTests {
    private func makeCommandAction(
        id: UUID = UUID(),
        title: String,
        command: String,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) -> TerminalAccessoryCustomAction {
        TerminalAccessoryCustomAction(
            id: id,
            title: title,
            kind: .command,
            commandContent: command,
            commandSendMode: .insert,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    @Test
    func defaultAccessoryProfileIncludesTabNavigationKey() {
        #expect(TerminalAccessoryProfile.defaultActiveItems.contains(.system(.tab)))
    }

    @Test
    func systemAccessoryActionsIncludeShiftTabAlternative() {
        #expect(TerminalAccessoryProfile.availableSystemActions.contains(.shiftTab))
    }

    @Test
    func normalizedDeletedSnippetClearsPayload() {
        let deletedAt = Date(timeIntervalSince1970: 1000)
        let profile = TerminalAccessoryProfile(
            schemaVersion: 1,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: TerminalAccessoryProfile.defaultActiveItems,
                updatedAt: .distantPast
            ),
            customActions: [
                makeCommandAction(
                    title: "Sensitive Command",
                    command: "export TOKEN=super-secret-value",
                    updatedAt: deletedAt,
                    deletedAt: deletedAt
                )
            ],
            updatedAt: deletedAt,
            lastWriterDeviceId: "device-a"
        )

        let normalized = profile.normalized()
        #expect(normalized.customActions.count == 1)
        #expect(normalized.customActions[0].isDeleted)
        #expect(normalized.customActions[0].title.isEmpty)
        #expect(normalized.customActions[0].commandContent.isEmpty)
    }

    @Test
    func normalizedEnforcesActiveSnippetCapDeterministically() {
        let totalActiveActions = TerminalAccessoryProfile.maxCustomActions + 5
        let activeActions: [TerminalAccessoryCustomAction] = (0..<totalActiveActions).map { index in
            makeCommandAction(
                title: "S\(index)",
                command: "echo \(index)",
                updatedAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        let deletedAt = Date(timeIntervalSince1970: 10_000)
        let deletedAction = makeCommandAction(
            title: "Legacy Secret",
            command: "rm -rf /tmp/secret",
            updatedAt: deletedAt,
            deletedAt: deletedAt
        )

        let profile = TerminalAccessoryProfile(
            schemaVersion: 1,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: [
                    .custom(activeActions[0].id),
                    .custom(activeActions[totalActiveActions - 1].id),
                    .system(.escape),
                    .system(.tab),
                    .system(.arrowUp),
                    .system(.arrowDown)
                ],
                updatedAt: .distantPast
            ),
            customActions: activeActions + [deletedAction],
            updatedAt: Date(timeIntervalSince1970: 10_001),
            lastWriterDeviceId: "device-a"
        )

        let normalized = profile.normalized()
        let activeActionsAfterNormalization = normalized.customActions.filter { !$0.isDeleted }
        #expect(activeActionsAfterNormalization.count == TerminalAccessoryProfile.maxCustomActions)

        let retainedIndexes = activeActionsAfterNormalization.compactMap { action in
            Int(action.title.dropFirst())
        }
        #expect(retainedIndexes.count == TerminalAccessoryProfile.maxCustomActions)
        #expect(retainedIndexes.min() == totalActiveActions - TerminalAccessoryProfile.maxCustomActions)
        #expect(retainedIndexes.max() == totalActiveActions - 1)

        #expect(!normalized.layout.activeItems.contains(.custom(activeActions[0].id)))
        #expect(normalized.layout.activeItems.contains(.custom(activeActions[totalActiveActions - 1].id)))

        let normalizedDeletedAction = normalized.customActions.first { $0.id == deletedAction.id }
        #expect(normalizedDeletedAction != nil)
        #expect(normalizedDeletedAction?.title.isEmpty == true)
        #expect(normalizedDeletedAction?.commandContent.isEmpty == true)
    }
}
