#if os(iOS)
import SwiftUI

extension ManageCustomThemesSheet {
    var platformBody: some View {
        Group {
            if sortedThemes.isEmpty {
                customThemesEmptyState
            } else {
                List {
                    Section {
                        ForEach(sortedThemes) { theme in
                            themeRow(theme)
                        }
                    } footer: {
                        customThemeCompatibilityNote
                    }
                }
            }
        }
        .navigationTitle("Custom Themes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    createThemeMenuItems
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .accessibilityIdentifier("vvterm.settings.customThemes.page")
    }

    private func themeRow(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let assignment = assignmentLabel(for: theme.name) {
                    Text(assignment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if case .needsRepair = theme.validationState {
                    Label("Needs Repair", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            Menu {
                applyMenuItems(themeName: theme.name)

                Divider()

                Button("Edit") {
                    themePendingEdit = theme
                }

                Button("Delete", role: .destructive) {
                    themePendingDeletion = theme
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Edit") {
                themePendingEdit = theme
            }
            .tint(.blue)

            Button("Delete", role: .destructive) {
                themePendingDeletion = theme
            }
        }
    }
}
#endif
