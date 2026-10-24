import AppKit
import XCTest
@testable import HSShot

final class EditorSessionTests: XCTestCase {
    @MainActor
    func testOpeningDraftReusesItsActiveEditorAfterFloatingPreviewEviction() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: UUID().uuidString)
        let model = AppModel(library: library)
        var previewRequests = 0
        // Always creating a preview here models a panel that has already been evicted.
        model.previewForEditing = { item in
            previewRequests += 1
            return QuickAccessPreviewState(item: item)
        }
        model.edit(original)
        let preview = try XCTUnwrap(model.activeEditorPreviews.values.first)
        let document = try XCTUnwrap(preview.document)
        let window = try editorWindow(title: original.title)
        defer { window.close() }
        let arrow = EditorAnnotation(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 60)],
                                     color: .red, width: 3)
        document.add(arrow)
        try EditorWindow.flushAutosaves()
        let draft = preview.item
        XCTAssertEqual(draft.isDraft, true)

        model.edit(draft)

        XCTAssertEqual(previewRequests, 1, "An active editor must outlive floating-preview eviction")
        XCTAssertEqual(model.activeEditorPreviews.count, 1)
        XCTAssertTrue(model.activeEditorPreviews[preview.sessionID] === preview)
        XCTAssertTrue(try editorWindow(title: original.title) === window)
        document.select(arrow.id)
        document.moveSelectedEndpoint(1, to: CGPoint(x: 110, y: 90))
        try EditorWindow.flushAutosaves()
        XCTAssertEqual(preview.item.id, draft.id)
        XCTAssertEqual(library.items.count, 2)
        let restored = try XCTUnwrap(library.editableProject(for: preview.item)).restore()
        XCTAssertEqual(restored.state.annotations.first?.points.last, CGPoint(x: 110, y: 90))

        window.performClose(nil)
        XCTAssertTrue(model.activeEditorPreviews.isEmpty)
    }

    @MainActor
    func testDeletingAnActiveDraftIsRejectedBeforeConfirmationAndRemainsSaveable() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let original = try library.add(image: image(), title: UUID().uuidString)
        let model = AppModel(library: library)
        model.edit(original)
        let preview = try XCTUnwrap(model.activeEditorPreviews.values.first)
        let document = try XCTUnwrap(preview.document)
        let window = try editorWindow(title: original.title)
        defer { window.close() }
        document.change { $0.padding = 24 }
        try EditorWindow.flushAutosaves()
        let draft = preview.item

        model.delete(draft)

        XCTAssertTrue(model.errorMessage?.contains("編集中") == true)
        XCTAssertNotNil(library.items.first { $0.id == draft.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: draft).path))
        document.change { $0.padding = 48 }
        try EditorWindow.flushAutosaves()
        XCTAssertEqual(preview.item.id, draft.id)
        XCTAssertEqual(try XCTUnwrap(library.editableProject(for: preview.item)).restore().state.padding, 48)
        window.performClose(nil)
        XCTAssertTrue(model.activeEditorPreviews.isEmpty)
    }

    @MainActor
    func testDeletedDraftCannotReopenThroughAStalePreview() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let document = try XCTUnwrap(EditorDocument(image: image()))
        document.setPadding(24)
        let draft = try library.saveDraft(image: XCTUnwrap(document.exportedImage()),
            project: EditorProject(document: document, sourceTitle: "Original"), title: "Draft")
        let stalePreview = QuickAccessPreviewState(item: draft)
        _ = try stalePreview.prepareDocument(using: library)
        let model = AppModel(library: library)
        var previewRequests = 0
        var dismissed: [UUID] = []
        model.previewForEditing = { _ in previewRequests += 1; return stalePreview }
        model.closeQuickPanelsForItem = { dismissed.append($0) }
        try library.delete(draft.id)

        model.edit(draft)

        XCTAssertEqual(previewRequests, 0)
        XCTAssertEqual(dismissed, [draft.id])
        XCTAssertTrue(model.activeEditorPreviews.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(library.items.isEmpty)
    }

    @MainActor
    func testOpeningAStaleDraftValueLoadsTheLatestFileGeneration() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let document = try XCTUnwrap(EditorDocument(image: image()))
        let title = UUID().uuidString
        let first = try library.saveDraft(image: XCTUnwrap(document.exportedImage()),
            project: EditorProject(document: document, sourceTitle: title), title: title)
        document.setPadding(24)
        let latest = try library.saveDraft(image: XCTUnwrap(document.exportedImage()),
            project: EditorProject(document: document, sourceTitle: title), title: title, replacing: first.id)
        let model = AppModel(library: library)

        model.edit(first)

        let window = try editorWindow(title: title)
        defer { window.close() }
        let preview = try XCTUnwrap(model.activeEditorPreviews.values.first)
        XCTAssertEqual(preview.item.filename, latest.filename)
        XCTAssertEqual(preview.document?.state.padding, 24)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    private func editorWindow(title: String) throws -> NSWindow {
        try XCTUnwrap(NSApplication.shared.windows.first {
            $0.title == "\(title) — HS Shot" && $0.delegate is EditorWindowController
        })
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HSShot.EditorSessionTests.\(UUID().uuidString)")
    }

    private func image() -> NSImage {
        let context = EditorRenderer.context(width: 160, height: 120)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 160, height: 120))
    }
}
