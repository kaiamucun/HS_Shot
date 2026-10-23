import XCTest
import AppKit
@testable import HSShot

final class LibraryStoreTests: XCTestCase {
    func makeImage() -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 80).fill()
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 120, height: 80))
    }

    func testImageImportSurvivesRestartAndFavorite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let item = try store.add(image: makeImage(), title: "日本語の撮影")
        XCTAssertEqual(item.width, 120)
        XCTAssertEqual(item.height, 80)
        try store.toggleFavorite(item.id)
        let restored = try LibraryStore(root: root)
        XCTAssertEqual(restored.items.count, 1)
        XCTAssertTrue(restored.items[0].isFavorite)
        XCTAssertEqual(restored.items[0].title, "日本語の撮影")
        XCTAssertNotNil(NSImage(contentsOf: restored.url(for: item)))
    }

    func testDeleteRemovesOnlyManagedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let first = try store.add(image: makeImage(), title: "first")
        let second = try store.add(image: makeImage(), title: "second")
        try store.delete(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: second).path))
        XCTAssertEqual(try LibraryStore(root: root).items.map(\.id), [second.id])
    }

    func testBrokenIndexIsPreservedAndMissingFilesAreFiltered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let item = try store.add(image: makeImage(), title: "missing")
        try FileManager.default.removeItem(at: store.url(for: item))
        XCTAssertTrue(try LibraryStore(root: root).items.isEmpty)
        let broken = Data("broken index".utf8)
        try broken.write(to: root.appendingPathComponent("library.json"))
        XCTAssertTrue(try LibraryStore(root: root).items.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix("library-corrupt-") }))
    }
}
