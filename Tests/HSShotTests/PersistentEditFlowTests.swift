import AppKit
import XCTest
@testable import HSShot

final class PersistentEditFlowTests: XCTestCase {
    @MainActor
    func testCompletedEditsReopenAfterPreviewDismissalAndRestartAndCanBeAdjustedAgain() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "撮影した画像")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let preview = QuickAccessPreviewState(item: original)
        let document = try preview.prepareDocument(using: library)
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 25, y: 35)], color: .red,
                                    width: 3, text: "修正前", fontSize: 18)
        let arrow = EditorAnnotation(tool: .arrow, points: [CGPoint(x: 25, y: 25), CGPoint(x: 80, y: 65)],
                                     color: .blue, width: 4)
        let crop = CGRect(x: 10, y: 10, width: 100, height: 80)
        document.add(text)
        document.add(arrow)
        document.crop(to: crop)
        document.setPadding(12)
        document.change { $0.background = .gradient }
        let model = AppModel(library: library)
        try document.saveToLibrary {
            try model.saveEditedImage($0, original: original, document: document, updating: preview)
        }
        let firstSaved = preview.item
        let firstPNG = try Data(contentsOf: library.url(for: firstSaved))
        XCTAssertTrue(preview.canResume(firstSaved))
        XCTAssertFalse(preview.canResume(original), "An earlier history item must not reuse its edited descendant's preview")

        // A new preview has no reference to the old editor, just as after dismissing its panel.
        let afterDismissal = QuickAccessPreviewState(item: firstSaved)
        let dismissedDocument = try afterDismissal.prepareDocument(using: library)
        XCTAssertFalse(dismissedDocument === document)
        XCTAssertEqual(dismissedDocument.state.annotations.map(\.id), [text.id, arrow.id])
        XCTAssertEqual(dismissedDocument.state.annotations.first?.text, "修正前")
        XCTAssertEqual(afterDismissal.sourceTitle, original.title)

        // Recreate the disk-backed store and preview to exclude all retained process state.
        let restartedLibrary = try LibraryStore(root: root)
        let restartedItem = try XCTUnwrap(restartedLibrary.items.first { $0.id == firstSaved.id })
        let restartedPreview = QuickAccessPreviewState(item: restartedItem)
        let suite = "HSShot.PersistentEditFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        preferences.padding = 96
        let restored = try restartedPreview.prepareDocument(using: restartedLibrary, preferences: preferences)
        XCTAssertFalse(restored === document)
        XCTAssertEqual(restored.base.width, 160)
        XCTAssertEqual(restored.base.height, 120)
        XCTAssertEqual(restored.state.annotations.map(\.id), [text.id, arrow.id])
        XCTAssertEqual(restored.state.annotations.last?.points, arrow.points)
        XCTAssertEqual(restored.state.crop, crop)
        XCTAssertEqual(restored.state.padding, 12, "Current preferences must not overwrite a saved project's padding")
        XCTAssertEqual(restored.state.background, .gradient)
        XCTAssertEqual(restored.dimensions, "124 × 104 px")
        XCTAssertEqual(try pixels(try XCTUnwrap(restored.exportedImage())),
                       try pixels(try XCTUnwrap(NSImage(data: firstPNG))))

        restored.updateText("再起動後に修正", id: text.id)
        restored.select(arrow.id)
        restored.moveSelectedEndpoint(1, to: CGPoint(x: 95, y: 75))
        restored.setLineWidth(7)
        XCTAssertTrue(restored.canUndo, "Restored objects must support new undoable edits")
        let restartedModel = AppModel(library: restartedLibrary)
        try restored.saveToLibrary {
            try restartedModel.saveEditedImage($0, original: restartedItem, document: restored, updating: restartedPreview)
        }
        let secondSaved = restartedPreview.item
        XCTAssertNotEqual(secondSaved.id, firstSaved.id)
        XCTAssertTrue(restartedPreview.canResume(secondSaved))
        XCTAssertFalse(restartedPreview.canResume(firstSaved))
        XCTAssertEqual(secondSaved.title, firstSaved.title, "Reopening must not append another edited suffix")
        XCTAssertEqual(try Data(contentsOf: restartedLibrary.url(for: firstSaved)), firstPNG)
        XCTAssertEqual(try Data(contentsOf: restartedLibrary.url(for: original)), originalBytes)

        let finalLibrary = try LibraryStore(root: root)
        let finalPreview = QuickAccessPreviewState(item: secondSaved)
        let finalDocument = try finalPreview.prepareDocument(using: finalLibrary)
        XCTAssertEqual(finalDocument.base.width, 160)
        XCTAssertEqual(finalDocument.base.height, 120)
        XCTAssertEqual(finalDocument.state.annotations.map(\.id), [text.id, arrow.id])
        XCTAssertEqual(finalDocument.state.annotations.first?.text, "再起動後に修正")
        XCTAssertEqual(finalDocument.state.annotations.last?.points.last, CGPoint(x: 95, y: 75))
        XCTAssertEqual(finalDocument.state.annotations.last?.width, 7)
        XCTAssertEqual(finalDocument.state.crop, crop)
        XCTAssertEqual(finalDocument.state.padding, 12)
        XCTAssertEqual(finalDocument.state.background, .gradient)
        let output = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: finalLibrary.url(for: secondSaved))))
        XCTAssertEqual(output.pixelsWide, 124)
        XCTAssertEqual(output.pixelsHigh, 104)

        // Opening an earlier history version must retain that version's independently saved objects.
        let earlier = try QuickAccessPreviewState(item: firstSaved).prepareDocument(using: finalLibrary)
        XCTAssertEqual(earlier.state.annotations.first?.text, "修正前")
        XCTAssertEqual(earlier.state.annotations.last?.points, arrow.points)
        XCTAssertEqual(earlier.state.annotations.last?.width, 4)
    }

    @MainActor
    func testSavedProjectRemainsEditableAfterOriginalCaptureIsDeleted() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "Original")
        let preview = QuickAccessPreviewState(item: original)
        let document = try preview.prepareDocument(using: library)
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 20, y: 20)], color: .red,
                                    width: 3, text: "元の文字", fontSize: 18)
        document.add(text)
        let saved = try AppModel(library: library).saveEditedImage(try XCTUnwrap(document.exportedImage()),
                                                                 original: original, document: document, updating: preview)
        try library.delete(original.id)

        let restartedLibrary = try LibraryStore(root: root)
        let restored = try QuickAccessPreviewState(item: saved).prepareDocument(using: restartedLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: original).path))
        XCTAssertEqual(restored.base.width, 160)
        XCTAssertEqual(restored.state.annotations.map(\.id), [text.id])
        restored.updateText("元画像の削除後も変更", id: text.id)
        XCTAssertEqual(restored.state.annotations.first?.text, "元画像の削除後も変更")
        XCTAssertNotNil(restored.exportedImage())
    }

    @MainActor
    func testFailedDurableSavePreservesSavedVersionAndPreviewAndCanRetry() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "Original")
        let firstPreview = QuickAccessPreviewState(item: original)
        let firstDocument = try firstPreview.prepareDocument(using: library)
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 20, y: 20)], color: .red,
                                    width: 3, text: "保存済み", fontSize: 18)
        firstDocument.add(text)
        let firstSaved = try AppModel(library: library).saveEditedImage(try XCTUnwrap(firstDocument.exportedImage()),
                                                                      original: original, document: firstDocument, updating: firstPreview)
        let preview = QuickAccessPreviewState(item: firstSaved)
        let document = try preview.prepareDocument(using: library)
        document.updateText("保存を再試行", id: text.id)
        let model = AppModel(library: library)
        model.selectedID = firstSaved.id
        let savedFiles = try mediaFiles(in: root)
        let index = root.appendingPathComponent("library.json")
        let indexBytes = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        XCTAssertThrowsError(try document.saveToLibrary {
            try model.saveEditedImage($0, original: firstSaved, document: document, updating: preview)
        })
        XCTAssertEqual(preview.item.id, firstSaved.id)
        XCTAssertEqual(model.selectedID, firstSaved.id)
        XCTAssertEqual(library.items.map(\.id), [firstSaved.id, original.id])
        XCTAssertTrue(preview.document === document)
        XCTAssertEqual(document.state.annotations.first?.text, "保存を再試行")
        XCTAssertEqual(try mediaFiles(in: root), savedFiles, "Failure must not alter prior projects or leave a half-saved image/project")

        try FileManager.default.removeItem(at: index)
        try indexBytes.write(to: index, options: .atomic)
        try document.saveToLibrary {
            try model.saveEditedImage($0, original: firstSaved, document: document, updating: preview)
        }
        let restartedLibrary = try LibraryStore(root: root)
        let retry = try QuickAccessPreviewState(item: preview.item).prepareDocument(using: restartedLibrary)
        let previous = try QuickAccessPreviewState(item: firstSaved).prepareDocument(using: restartedLibrary)
        XCTAssertEqual(retry.state.annotations.first?.text, "保存を再試行")
        XCTAssertEqual(previous.state.annotations.first?.text, "保存済み")
        XCTAssertEqual(restartedLibrary.items.count, 3)
    }

    @MainActor
    func testCorruptProjectDoesNotSilentlyCreateAFlattenedEditorAndCanRecover() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "Original")
        let document = try QuickAccessPreviewState(item: original).prepareDocument(using: library)
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 20, y: 20)], color: .red,
                                    width: 3, text: "失われてはいけない文字", fontSize: 18)
        document.add(text)
        let project = try EditorProject(document: document, sourceTitle: original.title)
        let saved = try library.add(image: XCTUnwrap(document.exportedImage()), project: project, title: "Edited")
        let sidecar = library.editableProjectURL(for: saved)
        let projectBytes = try Data(contentsOf: sidecar)
        let pngBytes = try Data(contentsOf: library.url(for: saved))
        try Data("not a valid project".utf8).write(to: sidecar, options: .atomic)

        let restartedLibrary = try LibraryStore(root: root)
        let preview = QuickAccessPreviewState(item: saved)
        XCTAssertThrowsError(try preview.prepareDocument(using: restartedLibrary))
        XCTAssertNil(preview.document, "A corrupted saved project must never become an editable flattened fallback")
        XCTAssertEqual(preview.item.id, saved.id)
        XCTAssertEqual(try Data(contentsOf: restartedLibrary.url(for: saved)), pngBytes)
        XCTAssertEqual(restartedLibrary.items.count, 2)

        try projectBytes.write(to: sidecar, options: .atomic)
        let recovered = try preview.prepareDocument(using: restartedLibrary)
        XCTAssertEqual(recovered.state.annotations.map(\.id), [text.id])
        XCTAssertEqual(recovered.state.annotations.first?.text, "失われてはいけない文字")
        XCTAssertEqual(recovered.base.width, 160)
    }

    @MainActor
    func testProjectRoundTripPreservesDisplayP3AnnotationsAndSemitransparentBasePixels() throws {
        let size = CGSize(width: 160, height: 120)
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120,
                                             bitsPerComponent: 8, bytesPerRow: 160 * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 0.4).cgColor)
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 75))
        let base = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: size)
        let document = try XCTUnwrap(EditorDocument(image: base))
        let displayP3 = NSColor(displayP3Red: 1, green: 0.3, blue: 0, alpha: 1)
        document.add(EditorAnnotation(tool: .rectangle,
                                      points: [CGPoint(x: 15, y: 15), CGPoint(x: 65, y: 65)],
                                      color: displayP3, width: 4))
        document.add(EditorAnnotation(tool: .arrow,
                                      points: [CGPoint(x: 50, y: 80), CGPoint(x: 140, y: 100)],
                                      color: displayP3, width: 4))
        document.add(EditorAnnotation(tool: .text, points: [CGPoint(x: 75, y: 35)],
                                      color: displayP3, width: 4, text: "P3", fontSize: 18))
        let before = try pixels(XCTUnwrap(document.exportedImage()))
        let alphaValues = stride(from: 3, to: before.count, by: 4).map { before[$0] }
        XCTAssertTrue(alphaValues.contains(0), "The fixture must include transparent pixels")
        XCTAssertTrue(alphaValues.contains { $0 > 0 && $0 < 255 }, "The fixture must include semitransparent pixels")

        let encoded = try JSONEncoder().encode(EditorProject(document: document, sourceTitle: "Display P3"))
        let restored = try JSONDecoder().decode(EditorProject.self, from: encoded).restore()
        let after = try pixels(XCTUnwrap(restored.exportedImage()))

        XCTAssertEqual(after, before, "Persisting and restoring a project must preserve the rendered colors and alpha")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-PersistentFlow-\(UUID().uuidString)")
    }

    private func image() -> NSImage {
        let context = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 160 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 160, height: 120))
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
                                             bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return Data(bytes: try XCTUnwrap(context.data), count: source.width * source.height * 4)
    }

    private func mediaFiles(in root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let file as URL in enumerator {
            guard file.lastPathComponent != "library.json",
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
        return files
    }
}
