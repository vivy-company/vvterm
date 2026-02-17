import Foundation
import Testing
@testable import VVTerm

struct TerminalAccessoryModelsTests {
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
            snippets: [
                TerminalSnippet(
                    title: "Sensitive Command",
                    content: "export TOKEN=super-secret-value",
                    sendMode: .insertAndEnter,
                    updatedAt: deletedAt,
                    deletedAt: deletedAt
                )
            ],
            updatedAt: deletedAt,
            lastWriterDeviceId: "device-a"
        )

        let normalized = profile.normalized()
        #expect(normalized.snippets.count == 1)
        #expect(normalized.snippets[0].isDeleted)
        #expect(normalized.snippets[0].title.isEmpty)
        #expect(normalized.snippets[0].content.isEmpty)
    }

    @Test
    func normalizedEnforcesActiveSnippetCapDeterministically() {
        let totalActiveSnippets = TerminalAccessoryProfile.maxSnippets + 5
        let activeSnippets: [TerminalSnippet] = (0..<totalActiveSnippets).map { index in
            TerminalSnippet(
                title: "S\(index)",
                content: "echo \(index)",
                sendMode: .insert,
                updatedAt: Date(timeIntervalSince1970: Double(index)),
                deletedAt: nil
            )
        }

        let deletedAt = Date(timeIntervalSince1970: 10_000)
        let deletedSnippet = TerminalSnippet(
            title: "Legacy Secret",
            content: "rm -rf /tmp/secret",
            sendMode: .insertAndEnter,
            updatedAt: deletedAt,
            deletedAt: deletedAt
        )

        let profile = TerminalAccessoryProfile(
            schemaVersion: 1,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: [
                    .snippet(activeSnippets[0].id),
                    .snippet(activeSnippets[totalActiveSnippets - 1].id),
                    .system(.escape),
                    .system(.tab),
                    .system(.arrowUp),
                    .system(.arrowDown)
                ],
                updatedAt: .distantPast
            ),
            snippets: activeSnippets + [deletedSnippet],
            updatedAt: Date(timeIntervalSince1970: 10_001),
            lastWriterDeviceId: "device-a"
        )

        let normalized = profile.normalized()
        let activeSnippetsAfterNormalization = normalized.snippets.filter { !$0.isDeleted }
        #expect(activeSnippetsAfterNormalization.count == TerminalAccessoryProfile.maxSnippets)

        let retainedIndexes = activeSnippetsAfterNormalization.compactMap { snippet in
            Int(snippet.title.dropFirst())
        }
        #expect(retainedIndexes.count == TerminalAccessoryProfile.maxSnippets)
        #expect(retainedIndexes.min() == totalActiveSnippets - TerminalAccessoryProfile.maxSnippets)
        #expect(retainedIndexes.max() == totalActiveSnippets - 1)

        #expect(!normalized.layout.activeItems.contains(.snippet(activeSnippets[0].id)))
        #expect(normalized.layout.activeItems.contains(.snippet(activeSnippets[totalActiveSnippets - 1].id)))

        let normalizedDeletedSnippet = normalized.snippets.first { $0.id == deletedSnippet.id }
        #expect(normalizedDeletedSnippet != nil)
        #expect(normalizedDeletedSnippet?.title.isEmpty == true)
        #expect(normalizedDeletedSnippet?.content.isEmpty == true)
    }
}
