#if os(macOS)
import SwiftUI

extension ProSettingsStatusHero {
    var platformBody: some View {
        ProSettingsStatusHeroLayout(
            state: state,
            onPrimaryAction: onPrimaryAction
        )
    }
}

private struct ProSettingsStatusHeroLayout: View {
    @ScaledMetric(relativeTo: .title2) private var iconSize = 34.0

    let state: ProSettingsUserState
    let onPrimaryAction: (ProSettingsPrimaryAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if state == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: iconSize)

            ProSettingsStatusContent(
                state: state,
                alignment: .leading,
                textAlignment: .leading
            )

            Spacer(minLength: 12)

            if let action = state.primaryAction {
                ProSettingsPrimaryActionButton(action: action) {
                    onPrimaryAction(action)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
#endif
