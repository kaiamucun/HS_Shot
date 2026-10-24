import AppKit
import XCTest
@testable import HSShot

final class EditPreviewLoopTests: XCTestCase {
    @MainActor
    func testDoneAndReopenRetainsEditableAnnotationsAndDoesNotCompoundPadding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "Original")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let preview = QuickAccessPreviewState(item: original)
        let sessionID = preview.sessionID
        let model = AppModel(library: library)
        let document = try XCTUnwrap(preview.prepareDocument(image: image()))
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 30, y: 30)], color: .white,
                                    width: 3, text: "修正前", fontSize: 18)
        let arrow = EditorAnnotation(tool: .arrow, points: [CGPoint(x: 25, y: 25), CGPoint(x: 70, y: 60)],
                                     color: .white, width: 3)
        let crop = CGRect(x: 10, y: 10, width: 100, height: 80)
        document.add(text)
        document.add(arrow)
        document.crop(to: crop)
        document.setPadding(12)
        document.select(arrow.id)
        document.moveSelectedEndpoint(1, to: CGPoint(x: 85, y: 65))
        try document.saveToLibrary { try model.saveEditedImage($0, original: original, document: document, updating: preview) }
        let firstSaved = preview.item
        let firstPNG = try Data(contentsOf: library.url(for: firstSaved))
        let flattened = try XCTUnwrap(NSImage(contentsOf: library.url(for: firstSaved)))

        // Reopening is intentionally supplied the latest flattened preview image. The retained
        // document must win; using that image as a new base would bake in annotations and padding.
        let reopened = try XCTUnwrap(preview.prepareDocument(image: flattened))
        XCTAssertTrue(reopened === document)
        XCTAssertEqual(preview.sessionID, sessionID)
        XCTAssertEqual(preview.originalItem.id, original.id)
        XCTAssertTrue(preview.represents(original.id))
        XCTAssertTrue(preview.represents(firstSaved.id))
        XCTAssertEqual(reopened.base.width, 160)
        XCTAssertEqual(reopened.base.height, 120)
        XCTAssertEqual(reopened.state.annotations.map(\.id), [text.id, arrow.id])
        XCTAssertEqual(reopened.state.annotations.last?.points.last, CGPoint(x: 85, y: 65))
        XCTAssertEqual(reopened.state.crop, crop)
        XCTAssertEqual(reopened.state.padding, 12)
        XCTAssertTrue(reopened.canUndo)

        reopened.undo()
        XCTAssertEqual(reopened.state.annotations.last?.points.last, CGPoint(x: 70, y: 60))
        reopened.redo()
        XCTAssertEqual(reopened.state.annotations.last?.points.last, CGPoint(x: 85, y: 65))
        try reopened.saveToLibrary { try model.saveEditedImage($0, original: firstSaved, document: reopened, updating: preview) }
        let unchangedPNG = try Data(contentsOf: library.url(for: preview.item))
        XCTAssertEqual(unchangedPNG, firstPNG)
        let unchangedBitmap = try XCTUnwrap(NSBitmapImageRep(data: unchangedPNG))
        XCTAssertEqual(unchangedBitmap.pixelsWide, 124)
        XCTAssertEqual(unchangedBitmap.pixelsHigh, 104)

        reopened.updateText("修正後", id: text.id)
        XCTAssertEqual(reopened.state.annotations.first?.id, text.id)
        XCTAssertEqual(reopened.state.annotations.first?.text, "修正後")
        reopened.undo()
        XCTAssertEqual(reopened.state.annotations.first?.text, "修正前")
        reopened.redo()
        let secondSaved = preview.item
        try reopened.saveToLibrary { try model.saveEditedImage($0, original: secondSaved, document: reopened, updating: preview) }
        XCTAssertTrue(preview.represents(secondSaved.id))
        XCTAssertNotEqual(try Data(contentsOf: library.url(for: preview.item)), firstPNG)
        XCTAssertEqual(try Data(contentsOf: library.url(for: original)), originalBytes)
        XCTAssertEqual(library.items.count, 4)
    }

    @MainActor
    func testSeparatePreviewsKeepIndependentEditableSessions() throws {
        let first = QuickAccessPreviewState(item: item("First"))
        let second = QuickAccessPreviewState(item: item("Second"))
        let firstDocument = try XCTUnwrap(first.prepareDocument(image: image()))
        let secondDocument = try XCTUnwrap(second.prepareDocument(image: image()))
        firstDocument.setPadding(24)
        firstDocument.add(EditorAnnotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], color: .white, width: 2))
        first.replace(sourceID: first.originalItem.id, with: item("Edited first"))

        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertFalse(firstDocument === secondDocument)
        XCTAssertTrue(secondDocument.state.annotations.isEmpty)
        XCTAssertEqual(secondDocument.state.padding, 0)
        XCTAssertFalse(secondDocument.canUndo)
        XCTAssertFalse(second.represents(first.item.id))
        XCTAssertTrue(second.prepareDocument(image: image()) === secondDocument)
    }

    @MainActor
    func testCompletingEvictedPreviewDoesNotReplaceANewSessionForTheSameOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "Original")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let model = AppModel(library: library)
        // An editor can retain an older session after its floating panel is evicted. Opening
        // the same library item now creates a separate session with the same original item ID.
        let oldPreview = QuickAccessPreviewState(item: original)
        let oldDocument = try XCTUnwrap(oldPreview.prepareDocument(image: image()))
        oldDocument.setPadding(12)
        let newPreview = QuickAccessPreviewState(item: original)
        let newDocument = try XCTUnwrap(newPreview.prepareDocument(image: image()))
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 30, y: 30)], color: .white,
                                    width: 3, text: "新しい編集", fontSize: 18)
        newDocument.add(text)
        let newDraft = try XCTUnwrap(newDocument.exportedImage()?.tiffRepresentation)

        let oldSaved = try model.saveEditedImage(try XCTUnwrap(oldDocument.exportedImage()),
                                                original: original, document: oldDocument, updating: oldPreview)

        XCTAssertNotEqual(oldPreview.sessionID, newPreview.sessionID)
        XCTAssertEqual(oldPreview.item.id, oldSaved.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: oldPreview.item).path))
        XCTAssertEqual(newPreview.item.id, original.id)
        XCTAssertFalse(newPreview.represents(oldSaved.id))
        XCTAssertTrue(newPreview.document === newDocument)
        XCTAssertEqual(newDocument.state.annotations.map(\.id), [text.id])
        XCTAssertEqual(newDocument.state.annotations.first?.text, "新しい編集")
        XCTAssertEqual(newDocument.state.padding, 0)
        XCTAssertEqual(newDocument.exportedImage()?.tiffRepresentation, newDraft)
        XCTAssertTrue(newDocument.canUndo)

        let newSaved = try model.saveEditedImage(try XCTUnwrap(newDocument.exportedImage()),
                                                original: original, document: newDocument, updating: newPreview)
        XCTAssertEqual(newPreview.item.id, newSaved.id)
        XCTAssertEqual(oldPreview.item.id, oldSaved.id)
        XCTAssertFalse(oldPreview.represents(newSaved.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: newPreview.item).path))
        XCTAssertEqual(try Data(contentsOf: library.url(for: original)), originalBytes)
        XCTAssertEqual(library.items.count, 3)
    }

    @MainActor
    func testCompleteCommitsLiveTextBeforePersistingAndClosesOnce() throws {
        _ = NSApplication.shared
        let document = try XCTUnwrap(EditorDocument(image: image()))
        document.tool = .text
        var savedTexts: [String] = []
        var closeCount = 0
        let controller = EditorWindowController(document: document, title: "Live text", onSave: { _ in
            savedTexts = document.state.annotations.map(\.text)
        }, onClose: { closeCount += 1 })
        let window = try XCTUnwrap(controller.window)
        let canvas = AnnotationCanvas(document: document)
        window.contentView = canvas
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 300, y: 200),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        fieldEditor.insertText("完了前に入力した文字", replacementRange: fieldEditor.selectedRange())

        try controller.completeEditing()

        XCTAssertEqual(savedTexts, ["完了前に入力した文字"])
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(window.isVisible)
        window.close()
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testClosingWithoutDoneKeepsLiveTextInTheEditableDraftWithoutSaving() throws {
        _ = NSApplication.shared
        let document = try XCTUnwrap(EditorDocument(image: image()))
        document.tool = .text
        var saveCount = 0
        var closeCount = 0
        let controller = EditorWindowController(document: document, title: "Keep draft", onSave: { _ in
            saveCount += 1
        }, onClose: { closeCount += 1 })
        let window = try XCTUnwrap(controller.window)
        let canvas = AnnotationCanvas(document: document)
        window.contentView = canvas
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 300, y: 200),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        fieldEditor.insertText("途中の編集も保持", replacementRange: fieldEditor.selectedRange())

        controller.close()

        XCTAssertEqual(document.state.annotations.map(\.text), ["途中の編集も保持"])
        XCTAssertTrue(document.canUndo)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(closeCount, 1)
        window.close()
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testFailedCompletionDoesNotCloseOrReplacePreviewAndCanRetry() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "Original")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let preview = QuickAccessPreviewState(item: original)
        let document = try XCTUnwrap(preview.prepareDocument(image: image()))
        document.setPadding(12)
        let model = AppModel(library: library)
        model.selectedID = original.id
        var closeCount = 0
        let controller = EditorWindowController(document: document, title: "Retry", onSave: { image in
            try model.saveEditedImage(image, original: original, document: document, updating: preview)
        }, onClose: { closeCount += 1 })
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try controller.completeEditing())
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(preview.item.id, original.id)
        XCTAssertEqual(model.selectedID, original.id)
        XCTAssertEqual(library.items.map(\.id), [original.id])
        XCTAssertEqual(document.state.padding, 12)

        try FileManager.default.removeItem(at: index)
        try controller.completeEditing()
        XCTAssertEqual(closeCount, 1)
        XCTAssertNotEqual(preview.item.id, original.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: preview.item).path))
        XCTAssertNotEqual(try Data(contentsOf: library.url(for: preview.item)), originalBytes)
        XCTAssertEqual(model.selectedID, preview.item.id)
        XCTAssertEqual(try Data(contentsOf: library.url(for: original)), originalBytes)
        XCTAssertTrue(preview.document === document)
    }

    @MainActor
    func testOpeningSameSessionReusesItsWindowAndCloseReleasesIt() throws {
        _ = NSApplication.shared
        let sessionID = UUID()
        let document = try XCTUnwrap(EditorDocument(image: image()))
        var closeCount = 0
        let first = EditorWindow.open(sessionID: sessionID, document: document, title: "Repeated open", onSave: { _ in }, onClose: { closeCount += 1 })
        defer { first.close() }
        let second = EditorWindow.open(sessionID: sessionID, document: document, title: "Repeated open", onSave: { _ in }, onClose: { closeCount += 1 })
        XCTAssertTrue(first === second)
        first.close()
        XCTAssertEqual(closeCount, 1)

        let reopened = EditorWindow.open(sessionID: sessionID, document: document, title: "Reopened", onSave: { _ in }, onClose: { closeCount += 1 })
        defer { reopened.close() }
        XCTAssertFalse(reopened === first)
        reopened.close()
        XCTAssertEqual(closeCount, 2)
    }

    private func item(_ title: String) -> CaptureItem {
        CaptureItem(id: UUID(), title: title, filename: "capture.png", kind: .image,
                    createdAt: Date(), width: 160, height: 120, byteCount: 128, isFavorite: false)
    }

    private func image() -> NSImage {
        let context = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 160 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 160, height: 120))
    }
}
