#if os(macOS)
import AppKit

enum SyncSettingsAccessibilityAnnouncement {
    static func post(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
    }
}
#endif
