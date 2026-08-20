import SwiftUI

struct ProSettingsStatusHero: View {
    let state: ProSettingsUserState
    let onPrimaryAction: (ProSettingsPrimaryAction) -> Void

    var body: some View {
        platformBody
    }
}

struct ProSettingsPrimaryActionButton: View {
    let action: ProSettingsPrimaryAction
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Text(action.title)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.orange)
        .accessibilityIdentifier("vvterm.settings.pro.action.primary")
    }
}

struct ProSettingsStatusContent: View {
    let state: ProSettingsUserState
    let alignment: HorizontalAlignment
    let textAlignment: TextAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(state.title)
                .font(.title2.weight(.semibold))

            if let renewalDate = state.renewalDate {
                Text("Renews \(renewalDate, format: .dateTime.month().day().year())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vvterm.settings.pro.statusHero")
    }
}
