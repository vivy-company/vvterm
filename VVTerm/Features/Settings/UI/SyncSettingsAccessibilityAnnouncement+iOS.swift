#if os(iOS)
import UIKit

enum SyncSettingsAccessibilityAnnouncement {
    static func post(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
#endif
