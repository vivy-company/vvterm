#if os(macOS)
import SwiftUI

extension TrustedHostsSettingsView {
    func platformHostRow(for knownHost: KnownHostSettingsItem) -> some View {
        TrustedHostSettingsRow(knownHost: knownHost)
            .contextMenu {
                resetAction(for: knownHost)
            }
    }
}
#endif
