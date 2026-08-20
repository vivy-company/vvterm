import Testing
@testable import VVTerm

struct RemoteMediaPreviewPolicyTests {
    @Test
    func acceptsBoundedMediaHeaders() {
        #expect(RemoteMediaPreviewPolicy.permits(width: 3_840, height: 2_160, frameCount: 1))
    }

    @Test(arguments: [
        (width: 0.0, height: 100.0, frames: 1),
        (width: .infinity, height: 100.0, frames: 1),
        (width: 20_000.0, height: 100.0, frames: 1),
        (width: 10_000.0, height: 10_000.0, frames: 1),
        (width: 100.0, height: 100.0, frames: 601)
    ])
    func rejectsUnsafeMediaHeaders(width: Double, height: Double, frames: Int) {
        #expect(!RemoteMediaPreviewPolicy.permits(
            width: width,
            height: height,
            frameCount: frames
        ))
    }

    @Test
    func rejectsUnboundedVideoDuration() {
        #expect(!RemoteMediaPreviewPolicy.permits(
            width: 1_920,
            height: 1_080,
            frameCount: 1,
            durationSeconds: .infinity
        ))
    }
}
