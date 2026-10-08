import SwiftUI
import Testing
@testable import VVTerm

struct NoticeLayoutPolicyTests {
    @Test
    func foldedDetailCentersBetweenSidebarAndControlRail() {
        let bounds = NoticeLayoutPolicy.horizontalBounds(
            size: CGSize(width: 1000, height: 700),
            safeAreaInsets: EdgeInsets(top: 0, leading: 500, bottom: 0, trailing: 80)
        )
        #expect(bounds.width == 420)
        #expect(bounds.midX == 710)
    }

    @Test
    func sideBarInsetKeepsNoticesInsideContent() {
        let bounds = NoticeLayoutPolicy.horizontalBounds(
            size: CGSize(width: 600, height: 400),
            safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 96)
        )
        #expect(bounds == CGRect(x: 0, y: 0, width: 504, height: 400))
    }

    @Test
    func unequalInsetsCenterNoticesWithinSafeContent() {
        let bounds = NoticeLayoutPolicy.horizontalBounds(
            size: CGSize(width: 900, height: 600),
            safeAreaInsets: EdgeInsets(top: 30, leading: 24, bottom: 20, trailing: 96)
        )
        #expect(bounds.minX == 24)
        #expect(bounds.maxX == 804)
        #expect(bounds.midX == 414)
        // Vertical placement remains controlled by the host's inset behavior.
        #expect(bounds.height == 600)
    }

    @Test
    func narrowPanesDoNotProduceNegativeWidths() {
        let bounds = NoticeLayoutPolicy.horizontalBounds(
            size: CGSize(width: 40, height: 100),
            safeAreaInsets: EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 96)
        )
        #expect(bounds == CGRect(x: 24, y: 0, width: 0, height: 100))
    }

    @Test
    func noInsetsPreserveContentBounds() {
        #expect(NoticeLayoutPolicy.horizontalBounds(
            size: CGSize(width: 360, height: 600), safeAreaInsets: EdgeInsets()
        ) == CGRect(x: 0, y: 0, width: 360, height: 600))
    }
}
