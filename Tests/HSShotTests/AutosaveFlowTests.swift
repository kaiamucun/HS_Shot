import AppKit
import XCTest
@testable import HSShot

final class AutosaveFlowTests: XCTestCase {
    @MainActor
    func testLiveDraftSurvivesRestartAndDonePromotesItWithoutDuplicatingHistory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "撮影した画像")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let model = AppModel(library: library)
        model.selectedID = original.id
        let preview = QuickAccessPreviewState(item: original)
        let document = try preview.prepareDocument(using: library)
        let arrow = EditorAnnotation(tool: .arrow, points: [CGPoint(x: 25, y: 25), CGPoint(x: 100, y: 75)],
                                     color: .red, width: 4)
        document.add(arrow)
        var liveText = EditorAnnotation(tool: .text, points: [CGPoint(x: 30, y: 40)], color: .white,
                                        width: 3, text: "未確定の入力", fontSize: 18)
        document.setLiveText(liveText, replacing: nil)
        let first = try autosave(document, model: model, preview: preview)
        XCTAssertEqual(document.state.annotations.map(\.id), [arrow.id], "Autosaving must not commit the field editor")
        XCTAssertEqual(preview.item, first)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertTrue(preview.represents(original.id))
        XCTAssertTrue(preview.represents(first.id))
        XCTAssertEqual(first.isDraft, true)
        XCTAssertEqual(library.items.count, 2)

        liveText.text = "入力を続けても同じ下書き"
        document.setLiveText(liveText, replacing: nil)
        let second = try autosave(document, model: model, preview: preview)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(library.items.count, 2)
        XCTAssertEqual(try Data(contentsOf: library.url(for: original)), originalBytes)

        // Reconstruct every model object from disk, excluding both preview and document retention.
        let restartedLibrary = try LibraryStore(root: root)
        let restartedItem = try XCTUnwrap(restartedLibrary.items.first { $0.id == first.id })
        let restartedPreview = QuickAccessPreviewState(item: restartedItem)
        let restored = try restartedPreview.prepareDocument(using: restartedLibrary)
        let restartedModel = AppModel(library: restartedLibrary)
        restartedModel.selectedID = restartedItem.id
        XCTAssertEqual(restartedPreview.sourceTitle, original.title)
        XCTAssertEqual(restored.state.annotations.map(\.id), [arrow.id, liveText.id])
        XCTAssertEqual(restored.state.annotations.last?.text, liveText.text)
        XCTAssertEqual(restored.base.width, 160)
        restored.updateText("再起動後に修正", id: liveText.id)
        restored.select(arrow.id)
        restored.moveSelectedEndpoint(1, to: CGPoint(x: 130, y: 90))
        let third = try autosave(restored, model: restartedModel, preview: restartedPreview)
        XCTAssertEqual(third.id, first.id)
        XCTAssertEqual(restartedLibrary.items.count, 2)

        let completed = try restartedModel.saveEditedImage(XCTUnwrap(restored.exportedImage()), original: restartedItem,
                                                           document: restored, updating: restartedPreview)
        XCTAssertEqual(completed.id, first.id)
        XCTAssertNotEqual(completed.isDraft, true)
        XCTAssertEqual(completed.title, "撮影した画像 — 編集済み")
        XCTAssertEqual(restartedPreview.item, completed)
        XCTAssertEqual(restartedModel.selectedID, completed.id)
        XCTAssertEqual(restartedLibrary.items.count, 2)
        let completedPNG = try Data(contentsOf: restartedLibrary.url(for: completed))
        let completedProject = try Data(contentsOf: restartedLibrary.editableProjectURL(for: completed))

        // Editing again after Done creates an independent draft, preserving the completed version.
        restored.updateText("完了後の次の編集", id: liveText.id)
        let nextDraft = try autosave(restored, model: restartedModel, preview: restartedPreview)
        XCTAssertNotEqual(nextDraft.id, completed.id)
        XCTAssertEqual(nextDraft.isDraft, true)
        XCTAssertEqual(restartedPreview.item.id, nextDraft.id)
        XCTAssertEqual(restartedLibrary.items.count, 3)
        XCTAssertEqual(try Data(contentsOf: restartedLibrary.url(for: completed)), completedPNG)
        XCTAssertEqual(try Data(contentsOf: restartedLibrary.editableProjectURL(for: completed)), completedProject)
        XCTAssertEqual(try Data(contentsOf: restartedLibrary.url(for: original)), originalBytes)

        let finalLibrary = try LibraryStore(root: root)
        let earlier = try QuickAccessPreviewState(item: completed).prepareDocument(using: finalLibrary)
        let latestPreview = QuickAccessPreviewState(item: nextDraft)
        let latest = try latestPreview.prepareDocument(using: finalLibrary)
        XCTAssertEqual(earlier.state.annotations.last?.text, "再起動後に修正")
        XCTAssertEqual(latest.state.annotations.last?.text, "完了後の次の編集")
        XCTAssertEqual(latest.state.annotations.first?.points.last, CGPoint(x: 130, y: 90))
        XCTAssertEqual(latestPreview.sourceTitle, original.title)
    }

    @MainActor
    func testFailedInitialAndRepeatedAutosavesKeepPreviewAndSelectionStableAndCanRetry() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "保存を再試行")
        let originalBytes = try Data(contentsOf: library.url(for: original))
        let model = AppModel(library: library)
        model.selectedID = original.id
        let preview = QuickAccessPreviewState(item: original)
        let document = try preview.prepareDocument(using: library)
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 30, y: 40)], color: .white,
                                    width: 3, text: "最初の変更", fontSize: 18)
        document.add(text)
        let index = root.appendingPathComponent("library.json")
        var indexBytes = try Data(contentsOf: index)
        try blockIndex(index)

        XCTAssertThrowsError(try autosave(document, model: model, preview: preview))
        XCTAssertEqual(preview.item, original)
        XCTAssertEqual(model.selectedID, original.id)
        XCTAssertEqual(library.items, [original])
        XCTAssertEqual(document.state.annotations.first?.text, "最初の変更")
        XCTAssertEqual(try Data(contentsOf: library.url(for: original)), originalBytes)
        try restoreIndex(index, bytes: indexBytes)
        let saved = try autosave(document, model: model, preview: preview)
        let savedPNG = try Data(contentsOf: library.url(for: saved))
        let savedProject = try Data(contentsOf: library.editableProjectURL(for: saved))
        indexBytes = try Data(contentsOf: index)
        document.updateText("次の変更も再試行", id: text.id)
        try blockIndex(index)

        XCTAssertThrowsError(try autosave(document, model: model, preview: preview))
        XCTAssertEqual(preview.item, saved)
        XCTAssertEqual(model.selectedID, saved.id)
        XCTAssertEqual(library.items.map(\.id), [saved.id, original.id])
        XCTAssertEqual(try Data(contentsOf: library.url(for: saved)), savedPNG)
        XCTAssertEqual(try Data(contentsOf: library.editableProjectURL(for: saved)), savedProject)
        XCTAssertEqual(document.state.annotations.first?.text, "次の変更も再試行")

        try restoreIndex(index, bytes: indexBytes)
        let retried = try autosave(document, model: model, preview: preview)
        XCTAssertEqual(retried.id, saved.id)
        XCTAssertEqual(preview.item, retried)
        XCTAssertEqual(model.selectedID, retried.id)
        XCTAssertEqual(library.items.count, 2)
        let restarted = try LibraryStore(root: root)
        let restored = try QuickAccessPreviewState(item: retried).prepareDocument(using: restarted)
        XCTAssertEqual(restored.state.annotations.first?.text, "次の変更も再試行")
        XCTAssertEqual(try Data(contentsOf: restarted.url(for: original)), originalBytes)
    }

    @MainActor
    func testBackgroundAutosaveDoesNotStealSelectionFromAnotherHistoryItem() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: "編集中")
        let selected = try library.add(image: image(), title: "閲覧中")
        let model = AppModel(library: library)
        model.selectedID = selected.id
        let preview = QuickAccessPreviewState(item: original)
        let document = try preview.prepareDocument(using: library)
        document.setPadding(24)

        let draft = try autosave(document, model: model, preview: preview)

        XCTAssertEqual(model.selectedID, selected.id)
        XCTAssertEqual(preview.item.id, draft.id)
        document.setPadding(48)
        let updated = try autosave(document, model: model, preview: preview)
        XCTAssertEqual(updated.id, draft.id)
        XCTAssertEqual(model.selectedID, selected.id)
        XCTAssertEqual(library.items.count, 3)
    }

    @MainActor
    private func autosave(_ document: EditorDocument, model: AppModel,
                          preview: QuickAccessPreviewState) throws -> CaptureItem {
        try model.autosaveEditedImage(XCTUnwrap(document.autosaveImage()), document: document, updating: preview)
    }

    private func blockIndex(_ index: URL) throws {
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
    }

    private func restoreIndex(_ index: URL, bytes: Data) throws {
        try FileManager.default.removeItem(at: index)
        try bytes.write(to: index, options: .atomic)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HSShot.AutosaveFlowTests.\(UUID().uuidString)")
    }

    private func image() -> NSImage {
        let context = EditorRenderer.context(width: 160, height: 120)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 160, height: 120))
    }
}
