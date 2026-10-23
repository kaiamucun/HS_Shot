import XCTest
import AppKit
@testable import HSShot

final class AppModelTests: XCTestCase {
    @MainActor
    func testCapturedFileSurvivesMetadataWriteFailureWithRecoveryPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try LibraryStore(root: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("finished-capture.png")
        try makePNG().write(to: source)
        let model = AppModel(library: library)
        // A directory in place of the metadata file reliably prevents an atomic JSON write.
        try FileManager.default.createDirectory(at: library.root.appendingPathComponent("library.json"), withIntermediateDirectories: false)

        XCTAssertThrowsError(try model.storeCapturedFile(source, title: "保存に失敗する撮影")) { error in
            XCTAssertTrue(error.localizedDescription.contains(source.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNotNil(NSImage(contentsOf: source))
        XCTAssertTrue(library.items.isEmpty)
    }

    @MainActor
    func testCapturedFileIsRemovedOnlyAfterLibraryPersistenceSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try LibraryStore(root: directory.appendingPathComponent("Library", isDirectory: true))
        let source = directory.appendingPathComponent("finished-capture.png")
        try makePNG().write(to: source)
        let model = AppModel(library: library)

        let item = try model.storeCapturedFile(source, title: "保存した撮影")

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: item).path))
        XCTAssertEqual(try LibraryStore(root: library.root).items.map(\.id), [item.id])
    }

    @MainActor
    func testScrollFailureRemainsVisibleAndKeepsFramesForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(library: try LibraryStore(root: directory))
        let first = try XCTUnwrap(NSImage(data: makePNG()))
        let second = NSImage(size: NSSize(width: 12, height: 8))
        second.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 12, height: 8).fill(); second.unlockFocus()
        model.scrollingFrames = [first, second]
        model.scrollingActive = true

        model.finishScrolling()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.scrollingActive)
        XCTAssertEqual(model.scrollingFrames.count, 2)
        XCTAssertNotNil(model.scrollingError)
        model.cancelScrolling()
        XCTAssertNil(model.scrollingError)
        XCTAssertTrue(model.scrollingFrames.isEmpty)
    }

    private func makePNG() throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let pixels = representation.bitmapData { memset(pixels, 255, representation.bytesPerRow * representation.pixelsHigh) }
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
