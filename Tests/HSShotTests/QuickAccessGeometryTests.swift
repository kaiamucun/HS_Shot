import XCTest
import AppKit
@testable import HSShot

final class QuickAccessGeometryTests: XCTestCase {
    func testLandscapeCaptureUsesTheFixedPreviewFrame() {
        let size = QuickAccessGeometry.panelSize(for: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(size.width, 210, accuracy: 0.001)
        XCTAssertEqual(size.height, 150, accuracy: 0.001)
    }

    func testVeryWideCaptureUsesTheSameFixedPreviewFrame() {
        let size = QuickAccessGeometry.panelSize(for: CGSize(width: 8000, height: 100))
        XCTAssertEqual(size, CGSize(width: 210, height: 150))
    }

    func testTallCaptureUsesTheSameFixedPreviewFrame() {
        let size = QuickAccessGeometry.panelSize(for: CGSize(width: 100, height: 8000))
        XCTAssertEqual(size, CGSize(width: 210, height: 150))
    }

    func testInvalidImageDimensionsDoNotChangeTheFixedPreviewFrame() {
        for size in [CGSize.zero, CGSize(width: -1, height: 100), CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.nan)] {
            XCTAssertEqual(QuickAccessGeometry.panelSize(for: size), CGSize(width: 210, height: 150))
        }
    }
}
