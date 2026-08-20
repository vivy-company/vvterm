#if os(macOS)
import SwiftUI

extension ManageCustomThemesSheet {
    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Custom Themes") {
                onClose()
            }

            Divider()

            if sortedThemes.isEmpty {
                customThemesEmptyState
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sortedThemes) { theme in
                            let assignment = assignmentLabel(for: theme.name)
                            CustomThemeManagerRow(
                                theme: theme,
                                assignment: assignment,
                                usePerAppearanceTheme: themeSelection.usePerAppearanceTheme,
                                isHovered: hoveredThemeID == theme.id,
                                isSelected: assignment != nil,
                                onApply: { target in
                                    applyThemeSelection(themeName: theme.name, applyTarget: target)
                                },
                                onEdit: {
                                    themePendingEdit = theme
                                },
                                onDeleteRequest: {
                                    themePendingDeletion = theme
                                }
                            )
                            .onHover { hovering in
                                hoveredThemeID = hovering ? theme.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                customThemeCompatibilityNote
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            Divider()

            HStack {
                Menu {
                    createThemeMenuItems
                } label: {
                    Label("New Custom Theme", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 400, height: 500)
    }
}
#endif
