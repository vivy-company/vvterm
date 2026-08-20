import Foundation

nonisolated enum RemoteMediaPreviewPolicy {
    static let maxDimension = 16_384.0
    static let maxPixelCount = 64_000_000.0
    static let maxFrameCount = 600
    static let maxVideoDurationSeconds = 6 * 60 * 60.0

    static func permits(
        width: Double,
        height: Double,
        frameCount: Int,
        durationSeconds: Double? = nil
    ) -> Bool {
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              width <= maxDimension,
              height <= maxDimension,
              width <= maxPixelCount / height,
              frameCount > 0,
              frameCount <= maxFrameCount else {
            return false
        }
        guard let durationSeconds else { return true }
        return durationSeconds.isFinite
            && durationSeconds >= 0
            && durationSeconds <= maxVideoDurationSeconds
    }
}
