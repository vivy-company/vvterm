import Testing
@testable import VVTerm

@Suite
struct GhosttyScrollbarTests {
    @Test
    func validStateIsPreserved() {
        let scrollbar = Ghostty.Action.Scrollbar(total: 100, offset: 25, len: 20)

        #expect(scrollbar.total == 100)
        #expect(scrollbar.offset == 25)
        #expect(scrollbar.len == 20)
        #expect(scrollbar.rowsBelowViewport == 55)
        #expect(scrollbar.offsetAsInt == 25)
    }

    @Test
    func viewportLengthIsClampedBeforeOffset() {
        let scrollbar = Ghostty.Action.Scrollbar(total: 10, offset: 8, len: 20)

        #expect(scrollbar.offset == 0)
        #expect(scrollbar.len == 10)
        #expect(scrollbar.rowsBelowViewport == 0)
    }

    @Test
    func offsetIsClampedWithoutUnsignedOverflow() {
        let scrollbar = Ghostty.Action.Scrollbar(
            total: UInt64.max,
            offset: UInt64.max,
            len: 1
        )

        #expect(scrollbar.offset == UInt64.max - 1)
        #expect(scrollbar.rowsBelowViewport == 0)
        #expect(scrollbar.offsetAsInt == Int.max)
    }

    @Test
    func liveScrollRowConversionRejectsNonFiniteAndClampsRange() {
        #expect(Ghostty.Action.Scrollbar.clampedRowIndex(.nan) == nil)
        #expect(Ghostty.Action.Scrollbar.clampedRowIndex(.infinity) == nil)
        #expect(Ghostty.Action.Scrollbar.clampedRowIndex(-4) == 0)
        #expect(Ghostty.Action.Scrollbar.clampedRowIndex(12.9) == 12)
        #expect(
            Ghostty.Action.Scrollbar.clampedRowIndex(.greatestFiniteMagnitude)
                == Int.max
        )
    }
}
