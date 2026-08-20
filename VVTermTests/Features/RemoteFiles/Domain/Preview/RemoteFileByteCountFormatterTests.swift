import Testing
@testable import VVTerm

struct RemoteFileByteCountFormatterTests {
    @Test(arguments: [
        UInt64(Int64.max),
        UInt64(Int64.max) + 1,
        UInt64.max
    ])
    func formatsFullRemoteSizeRangeWithoutOverflow(_ byteCount: UInt64) {
        let value = RemoteFileByteCountFormatter.string(from: byteCount)

        #expect(!value.isEmpty)
        #expect(!value.contains("-"))
    }

    @Test
    func formatsUnsignedValuesAboveInt64AsExabytes() {
        let value = RemoteFileByteCountFormatter.string(from: .max)

        #expect(value.contains("EB"))
    }
}
