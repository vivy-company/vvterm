import Foundation

nonisolated enum FreeTierLimitPresentation {
    static func serverCountDescription(_ limit: Int) -> String {
        if limit == 1 {
            return String(localized: "1 server")
        }
        return String(format: String(localized: "%lld servers"), Int64(limit))
    }
}
