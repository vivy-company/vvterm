#if os(iOS)
import SwiftUI

extension TrustedHostsSettingsView {
    func platformHostRow(for knownHost: KnownHostSettingsItem) -> some View {
        TrustedHostSettingsRow(knownHost: knownHost)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                resetAction(for: knownHost)
            }
    }
}
#endif
