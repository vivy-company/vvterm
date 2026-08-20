import Foundation

nonisolated enum RemoteFileByteCountFormatter {
    private static let bytesPerExabyte = 1_000_000_000_000_000_000.0

    static func string(from byteCount: UInt64) -> String {
        if byteCount <= UInt64(Int64.max) {
            return ByteCountFormatter.string(
                fromByteCount: Int64(byteCount),
                countStyle: .file
            )
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let exabytes = Double(byteCount) / bytesPerExabyte
        let value = formatter.string(from: NSNumber(value: exabytes)) ?? String(exabytes)
        return "\(value) EB"
    }
}
