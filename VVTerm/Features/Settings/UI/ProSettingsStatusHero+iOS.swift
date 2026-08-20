#if os(iOS)
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
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 58.0

    let state: ProSettingsUserState
    let onPrimaryAction: (ProSettingsPrimaryAction) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if state == .checking {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: iconSize)

            ProSettingsStatusContent(
                state: state,
                alignment: .center,
                textAlignment: .center
            )

            if let action = state.primaryAction {
                ProSettingsPrimaryActionButton(action: action) {
                    onPrimaryAction(action)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}
#endif
