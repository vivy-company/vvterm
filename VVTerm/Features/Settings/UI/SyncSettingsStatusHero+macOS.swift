#if os(macOS)
import SwiftUI

extension SyncSettingsStatusHero {
    var platformBody: some View {
        StatusHeroLayout(
            state: state,
            lastSuccessfulSyncDate: lastSuccessfulSyncDate,
            primaryAction: primaryAction,
            onPrimaryAction: onPrimaryAction
        )
    }
}

private struct StatusHeroLayout: View {
    @ScaledMetric(relativeTo: .title2) private var iconSize = 34.0

    let state: SyncSettingsUserState
    let lastSuccessfulSyncDate: Date?
    let primaryAction: SyncSettingsPrimaryAction?
    let onPrimaryAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: state.statusHeroSystemImage)
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(state.statusHeroTint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.headline)
                    SyncSettingsStatusDetail(
                        state: state,
                        lastSuccessfulSyncDate: lastSuccessfulSyncDate
                    )
                    .font(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync Status")
            .accessibilityValue(state.title)
            .accessibilityIdentifier("vvterm.settings.sync.statusHero")

            Spacer(minLength: 12)

            if let primaryAction {
                SyncSettingsPrimaryActionButton(
                    action: primaryAction,
                    perform: onPrimaryAction
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
#endif
