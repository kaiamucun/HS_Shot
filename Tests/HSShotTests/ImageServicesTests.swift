import AppKit
import XCTest
@testable import HSShot

final class ImageServicesTests: XCTestCase {
    // Dropping a row, flipping the image, or resizing Retina captures breaks this comparison.
    func testOverlapPreservesEveryPixelAndNativeResolution() throws {
        let page = try pattern(width: 180, height: 420)
        let first = try frame(page, y: 0, height: 240, pointScale: 0.5)
        let second = try frame(page, y: 150, height: 240, pointScale: 0.5)

        let result = try ImageServices.stitch([first, second])
        let pixels = try cgImage(result)
        XCTAssertEqual(pixels.width, 180)
        XCTAssertEqual(pixels.height, 390)
        XCTAssertEqual(try rgba(pixels), try rgba(XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 180, height: 390)))))
    }

    func testDuplicateFramesDoNotRepeatRowsAcrossMultipleCaptures() throws {
        let page = try pattern(width: 96, height: 330)
        let first = try frame(page, y: 0, height: 170)
        let second = try frame(page, y: 80, height: 170)
        let third = try frame(page, y: 160, height: 170)

        let result = try cgImage(ImageServices.stitch([first, first, second, second, third]))
        XCTAssertEqual(result.height, 330)
        XCTAssertEqual(try rgba(result), try rgba(page))
    }

    func testMismatchedPixelWidthsAreRejectedEvenWhenPointSizesMatch() throws {
        let first = NSImage(cgImage: try pattern(width: 80, height: 120), size: NSSize(width: 80, height: 120))
        let second = NSImage(cgImage: try pattern(width: 82, height: 120), size: NSSize(width: 80, height: 120))

        XCTAssertThrowsError(try ImageServices.stitch([first, second])) { error in
            XCTAssertTrue(error.localizedDescription.contains("幅"))
        }
    }

    func testFramesWithoutOverlapAreRejected() throws {
        let page = try pattern(width: 96, height: 420)
        let first = try frame(page, y: 0, height: 120)
        let second = try frame(page, y: 280, height: 120)

        XCTAssertThrowsError(try ImageServices.stitch([first, second])) { error in
            XCTAssertTrue(error.localizedDescription.contains("重なり"))
        }
    }

    func testAmbiguousBlankOverlapIsRejected() throws {
        var firstBytes = [UInt8](repeating: 255, count: 96 * 120 * 4)
        var secondBytes = firstBytes
        for y in 0..<10 {
            for x in 0..<96 {
                let start = (y * 96 + x) * 4
                firstBytes[start] = 20
                secondBytes[((119 - y) * 96 + x) * 4 + 2] = 20
            }
        }
        let first = NSImage(cgImage: try image(width: 96, height: 120, bytes: firstBytes), size: .zero)
        let second = NSImage(cgImage: try image(width: 96, height: 120, bytes: secondBytes), size: .zero)
        XCTAssertThrowsError(try ImageServices.stitch([first, second])) { error in
            XCTAssertTrue(error.localizedDescription.contains("重なり"))
        }
    }

    func testChangedContentWithoutScrollingIsNotSilentlyDiscarded() throws {
        let page = try pattern(width: 96, height: 120)
        var changedBytes = [UInt8](try rgba(page))
        changedBytes[0] = changedBytes[0] == 255 ? 254 : changedBytes[0] + 1
        let first = NSImage(cgImage: page, size: .zero)
        let second = NSImage(cgImage: try image(width: 96, height: 120, bytes: changedBytes), size: .zero)

        XCTAssertThrowsError(try ImageServices.stitch([first, second]))
    }

    func testGrayscaleCapturesCanBeStitched() throws {
        let bytes = (0..<(80 * 230)).map { UInt8(truncatingIfNeeded: ($0 / 80) * 37 + ($0 % 80) * 17) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let page = try XCTUnwrap(CGImage(width: 80, height: 230, bitsPerComponent: 8, bitsPerPixel: 8,
                                        bytesPerRow: 80, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let result = try cgImage(ImageServices.stitch([frame(page, y: 0, height: 150), frame(page, y: 80, height: 150)]))
        XCTAssertEqual(result.width, 80)
        XCTAssertEqual(result.height, 230)
        XCTAssertEqual(try rgba(result), try rgba(page))
    }

    func testOversizedPixelDimensionsAreRejected() throws {
        let wide = NSImage(cgImage: try pattern(width: 32_769, height: 2), size: .zero)
        XCTAssertThrowsError(try ImageServices.stitch([wide])) { error in
            XCTAssertTrue(error.localizedDescription.contains("大き"))
        }
    }

    func testExcessivelyTallCombinedOutputIsRejected() throws {
        let page = try pattern(width: 32, height: 33_000)
        let first = try frame(page, y: 0, height: 17_000)
        let second = try frame(page, y: 16_000, height: 17_000)
        XCTAssertThrowsError(try ImageServices.stitch([first, second])) { error in
            XCTAssertTrue(error.localizedDescription.contains("大き"))
        }
    }

    func testSingleRetinaFrameKeepsOriginalPixelDimensionsAndOrientation() throws {
        let original = try pattern(width: 100, height: 140)
        let retina = NSImage(cgImage: original, size: NSSize(width: 50, height: 70))
        let result = try cgImage(ImageServices.stitch([retina]))
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 140)
        XCTAssertEqual(try rgba(result), try rgba(original))
    }

    func testEmptyInputIsRejected() {
        XCTAssertThrowsError(try ImageServices.stitch([]))
    }

    func testOCRRecognizesGeneratedJapaneseAndEnglishText() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 160,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 720, height: 160).fill()
        NSString(string: "HS SHOT 2026").draw(at: NSPoint(x: 36, y: 85), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black
        ])
        NSString(string: "日本語の文字").draw(at: NSPoint(x: 36, y: 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let rendered = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: .zero)

        let text = try await ImageServices.recognizeText(in: rendered)
        XCTAssertTrue(text.contains("2026"), "Recognized text: \(text)")
        XCTAssertTrue(text.uppercased().contains("SHOT"), "Recognized text: \(text)")
        XCTAssertTrue(text.contains("文字"), "Recognized text: \(text)")
    }

    private func pattern(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Coordinate-dependent noise gives every row and column a distinct identity.
        for y in 0..<height {
            for x in 0..<width {
                var value = UInt64(y * 104_729 + x * 15_485_863 + 31)
                value = (value ^ (value >> 13)) &* 1_103_515_245 &+ 12_345
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 19)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 31)
            }
        }
        return try image(width: width, height: height, bytes: bytes)
    }

    private func image(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func frame(_ page: CGImage, y: Int, height: Int, pointScale: Double = 1) throws -> NSImage {
        let crop = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: y, width: page.width, height: height)))
        return NSImage(cgImage: crop, size: NSSize(width: Double(page.width) * pointScale, height: Double(height) * pointScale))
    }

    private func cgImage(_ image: NSImage) throws -> CGImage {
        try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func rgba(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }
}
