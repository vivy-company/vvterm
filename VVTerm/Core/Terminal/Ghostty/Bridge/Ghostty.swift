import Foundation
import OSLog

enum Ghostty {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "Ghostty"
    )

    static let configDidReloadNotification = Notification.Name("GhosttyConfigDidReload")
}
