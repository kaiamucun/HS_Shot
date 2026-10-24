import XCTest
import AppKit
@testable import HSShot

final class QuickAccessPreviewTests: XCTestCase {
    @MainActor
    func testPreviewFollowsRepeatedEditsFromOriginalAndReplacement() {
        let original = item("Original")
        let first = item("First edit")
        let second = item("Second edit")
        let third = item("Edited again")
        let preview = QuickAccessPreviewState(item: original)
        preview.replace(sourceID: original.id, with: first)
        preview.replace(sourceID: original.id, with: second)
        XCTAssertEqual(preview.item.id, second.id)
        preview.replace(sourceID: second.id, with: third)
        XCTAssertEqual(preview.item.id, third.id)
        preview.replace(sourceID: item("Other capture").id, with: original)
        XCTAssertEqual(preview.item.id, third.id)
    }

    @MainActor
    func testSuccessfulEditPreservesOriginalAndPublishesPersistedReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(.white), title: "Original")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let model = AppModel(library: library)
        let preview = QuickAccessPreviewState(item: original)
        let saved = try model.saveEditedImage(image(.blue), original: original, updating: preview)
        XCTAssertEqual(preview.item.id, saved.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: preview.item).path))
        XCTAssertEqual(model.selectedID, saved.id)
        XCTAssertEqual(library.items.count, 2)
        XCTAssertEqual(try Data(contentsOf: library.url(for: original)), originalBytes)
        XCTAssertNotEqual(try Data(contentsOf: library.url(for: saved)), originalBytes)
    }

    @MainActor
    func testFailedEditDoesNotReplacePreviewOrSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(.white), title: "Original")
        let model = AppModel(library: library)
        let preview = QuickAccessPreviewState(item: original)
        model.selectedID = original.id
        try FileManager.default.removeItem(at: root.appendingPathComponent("library.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.saveEditedImage(image(.blue), original: original, updating: preview))
        XCTAssertEqual(preview.item.id, original.id)
        XCTAssertEqual(model.selectedID, original.id)
        XCTAssertEqual(library.items.map(\.id), [original.id])
    }

    private func item(_ title: String) -> CaptureItem {
        CaptureItem(id: UUID(), title: title, filename: "capture.png", kind: .image,
                    createdAt: Date(), width: 8, height: 8, byteCount: 128, isFavorite: false)
    }

    private func image(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        return image
    }
}
