#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import VVTerm

@MainActor
final class StatsViewportWidthTests: XCTestCase {
    func testContentUsesNativeScrollWidthAcrossSizeChanges() async throws {
        let probe = ViewportMeasurement()
        func viewport(width: CGFloat) -> some View {
            ScrollView {
                StatsAppearancePreviewContent(
                    preferences: .defaultValue(lastWriterDeviceId: "viewport-test")
                )
                    .overlay {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { probe.size = geometry.size }
                                .onChange(of: geometry.size) { probe.size = $0 }
                        }
                    }
            }
            .frame(width: width)
        }
        let host = UIHostingController(rootView: viewport(width: 480))
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 96)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1100, height: 400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for width in [CGFloat(480), 780, 280] {
            host.rootView = viewport(width: width)
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            // SwiftUI updates container measurements on the next layout pass.
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let actual = probe.size
            XCTAssertGreaterThan(actual.height, 0)
            XCTAssertEqual(actual.width, width, accuracy: 1,
                           "The dashboard must neither overflow nor subtract side insets twice.")
        }
    }
}

@MainActor
private final class ViewportMeasurement {
    var size = CGSize.zero
}
#endif
