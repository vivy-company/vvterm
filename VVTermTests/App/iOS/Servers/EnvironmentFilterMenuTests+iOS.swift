#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import VVTerm

@MainActor
final class EnvironmentFilterMenuTests: XCTestCase {
    func testMenuArrowAlignsWithNativeSessionDisclosure() async throws {
        guard #available(iOS 17, *) else { throw XCTSkip("Native collapsible sections need iOS 17.") }
        let probe = HeaderMeasurement()
        func list(textSize: DynamicTypeSize) -> some View {
            List {
                Section {
                    Text("Server")
                } header: {
                    HStack {
                        Text("Servers")
                        Spacer()
                        EnvironmentFilterMenu(selected: .constant(nil), environments: [], serverCounts: [:],
                                              onCreateCustom: {}, onEditCustom: { _ in }, onDeleteCustom: { _ in })
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.onAppear { probe.menu = geometry.frame(in: .global) }
                                .onChange(of: geometry.frame(in: .global)) { probe.menu = $0 }
                        }
                    }
                }
                Section(isExpanded: .constant(true)) {
                    Text("Session")
                } header: {
                    Text("Session header")
                        .background {
                            GeometryReader { geometry in
                                Color.clear.onAppear { probe.session = geometry.frame(in: .global) }
                                    .onChange(of: geometry.frame(in: .global)) { probe.session = $0 }
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.colorScheme, .light)
            .environment(\.layoutDirection, .leftToRight)
        }
        let host = UIHostingController(rootView: list(textSize: .large))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        for width in [CGFloat(400), 780] {
            for textSize in [DynamicTypeSize.large, .accessibility2] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                host.rootView = list(textSize: textSize)
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let menuArrow = try arrowBounds(in: image, header: probe.menu)
                let sessionArrow = try arrowBounds(in: image, header: probe.session)
                XCTAssertEqual(menuArrow.midX, sessionArrow.midX, accuracy: 1.5,
                               "Menu and native disclosure arrows must align at width \(width), text size \(textSize).")
                XCTAssertEqual(menuArrow.width, sessionArrow.width, accuracy: 1.5)
            }
        }
    }

    // Find the rightmost glyph in each header. Compare rendered arrows, not padded button frames.
    private func arrowBounds(in image: UIImage, header: CGRect) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        XCTAssertFalse(pixelOverflow || byteOverflow)
        guard !pixelOverflow, !byteOverflow else { throw HeaderTestError.invalidImage }
        var pixels = [UInt8](repeating: 0, count: byteCount)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        XCTAssertGreaterThan(header.height, 0)
        let top = max(0, min(height, Int(floor(header.minY * image.scale))))
        let bottom = max(top, min(height, Int(ceil(header.maxY * image.scale))))
        func containsGlyph(at x: Int) -> Bool {
            (top..<bottom).contains { y in
                let offset = (y * width + x) * 4
                return pixels[offset + 3] > 200 && pixels[offset] < 170
                    && pixels[offset + 1] < 170 && pixels[offset + 2] < 170
            }
        }
        let right = try XCTUnwrap((0..<width).last(where: containsGlyph))
        var left = right
        while left > 0, containsGlyph(at: left - 1) { left -= 1 }
        return CGRect(x: CGFloat(left) / image.scale, y: 0,
                      width: CGFloat(right - left + 1) / image.scale, height: 0)
    }

    private enum HeaderTestError: Error { case invalidImage }
}

@MainActor
private final class HeaderMeasurement {
    var menu = CGRect.zero
    var session = CGRect.zero
}
#endif
