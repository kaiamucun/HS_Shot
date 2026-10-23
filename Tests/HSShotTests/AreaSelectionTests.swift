import XCTest
import AppKit
@testable import HSShot

final class AreaSelectionTests: XCTestCase {
    func testRetinaSelectionUsesImagePixels() {
        XCTAssertEqual(AreaSelectionGeometry.pixelRect(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 120, y: 80), pointSize: CGSize(width: 200, height: 100), pixelSize: CGSize(width: 400, height: 200)), CGRect(x: 40, y: 60, width: 200, height: 100))
    }

    func testDraggingUpAndLeftSelectsTheSameArea() {
        XCTAssertEqual(AreaSelectionGeometry.pixelRect(from: CGPoint(x: 120, y: 80), to: CGPoint(x: 20, y: 30), pointSize: CGSize(width: 200, height: 100), pixelSize: CGSize(width: 400, height: 200)), CGRect(x: 40, y: 60, width: 200, height: 100))
    }

    func testDraggingBeyondTheDisplayClampsToItsImage() {
        XCTAssertEqual(AreaSelectionGeometry.pixelRect(from: CGPoint(x: -20, y: 30), to: CGPoint(x: 250, y: 150), pointSize: CGSize(width: 200, height: 100), pixelSize: CGSize(width: 400, height: 200)), CGRect(x: 0, y: 60, width: 400, height: 140))
    }

    func testFractionalSelectionIncludesEveryIntersectingPixel() {
        XCTAssertEqual(AreaSelectionGeometry.pixelRect(from: CGPoint(x: 5.25, y: 8.75), to: CGPoint(x: 34.25, y: 28.25), pointSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 200, height: 200)), CGRect(x: 10, y: 17, width: 59, height: 40))
    }

    func testEachDisplayUsesItsOwnScale() {
        XCTAssertEqual(AreaSelectionGeometry.pixelRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30), pointSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 100, height: 200)), CGRect(x: 10, y: 20, width: 20, height: 40))
    }

    func testEmptyAndInvalidSelectionsDoNotCreateCaptures() {
        let valid = CGSize(width: 200, height: 100)
        XCTAssertNil(AreaSelectionGeometry.pixelRect(from: .zero, to: .zero, pointSize: valid, pixelSize: valid))
        XCTAssertNil(AreaSelectionGeometry.pixelRect(from: .zero, to: CGPoint(x: 20, y: 0), pointSize: valid, pixelSize: valid))
        XCTAssertNil(AreaSelectionGeometry.pixelRect(from: .zero, to: CGPoint(x: 20, y: 20), pointSize: .zero, pixelSize: valid))
        XCTAssertNil(AreaSelectionGeometry.pixelRect(from: CGPoint(x: CGFloat.nan, y: 0), to: CGPoint(x: 20, y: 20), pointSize: valid, pixelSize: valid))
        XCTAssertNil(AreaSelectionGeometry.pixelRect(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 400, y: 300), pointSize: valid, pixelSize: valid))
    }

    func testCroppingKeepsTopAndBottomInTheCorrectOrientation() throws {
        // Raw CGImage rows run from the top: two red rows followed by two blue rows.
        let bytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255,
                              255, 0, 0, 255, 255, 0, 0, 255,
                              0, 0, 255, 255, 0, 0, 255, 255,
                              0, 0, 255, 255, 0, 0, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let top = try XCTUnwrap(AreaSelectionGeometry.crop(image, from: .zero, to: CGPoint(x: 2, y: 2), pointSize: CGSize(width: 2, height: 4)))
        let bottom = try XCTUnwrap(AreaSelectionGeometry.crop(image, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 2, y: 4), pointSize: CGSize(width: 2, height: 4)))
        XCTAssertEqual(top.width, 2)
        XCTAssertEqual(top.height, 2)
        XCTAssertEqual(firstPixel(top), [255, 0, 0, 255])
        XCTAssertEqual(firstPixel(bottom), [0, 0, 255, 255])
    }

    private func firstPixel(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: 4))
    }
}
