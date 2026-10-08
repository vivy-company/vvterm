#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import VVTerm

@MainActor
final class StatsViewportWidthTests: XCTestCase {
    func testCardsStayOnEachSideWhenFoldPositionChanges() async throws {
        let probe = FoldCardMeasurement()
        func grid(division: ClosedRange<CGFloat>?) -> some View {
            StatsCardsGridLayout(
                minimumColumnWidth: 320, spacing: 18,
                preferredColumnSpans: [1, 1, 2], division: division
            ) {
                ForEach(0..<3) { index in
                    Text("Card \(index)")
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { probe.frames[index] = geometry.frame(in: .global) }
                                    .onChange(of: geometry.frame(in: .global)) { probe.frames[index] = $0 }
                            }
                        }
                }
            }
            .frame(width: 840)
        }
        let host = UIHostingController(rootView: grid(division: 440...460))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 840, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for division in [CGFloat(440)...460, CGFloat(380)...400] {
            host.rootView = grid(division: division)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let left = try XCTUnwrap(probe.frames[0])
            let right = try XCTUnwrap(probe.frames[1])
            let nextRow = try XCTUnwrap(probe.frames[2])
            XCTAssertEqual(left.maxX, division.lowerBound - 9, accuracy: 1)
            XCTAssertEqual(right.minX, division.upperBound + 9, accuracy: 1)
            XCTAssertEqual(right.maxX, 840, accuracy: 1)
            XCTAssertEqual(nextRow.width, left.width, accuracy: 1,
                           "A wide card must not span the fold.")
            XCTAssertGreaterThan(nextRow.minY, left.maxY)
        }
    }

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

@MainActor
private final class FoldCardMeasurement {
    var frames: [Int: CGRect] = [:]
}
#endif
