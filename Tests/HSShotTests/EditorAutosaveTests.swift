import AppKit
import XCTest
@testable import HSShot

final class EditorAutosaveTests: XCTestCase {
    @MainActor
    func testBackgroundAutosavePersistsLiveTextWithoutEndingInputOrAddingUndoSteps() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let document = try XCTUnwrap(EditorDocument(image: image()))
        var draftID: UUID?
        let controller = EditorWindowController(document: document, title: "Live draft", onSave: { _ in },
            onAutosave: { image in
                draftID = try self.persist(document, image: image, in: library, replacing: draftID).id
            }, autosaveDelay: 60, onClose: {})
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let editor = try beginText(in: window, document: document, text: "入力途中のテキスト")
        XCTAssertTrue(document.state.annotations.isEmpty)
        XCTAssertFalse(document.canUndo)

        try controller.autosaveNow()

        let restored = try restoredDocument(in: root, id: XCTUnwrap(draftID))
        XCTAssertEqual(restored.state.annotations.map(\.text), ["入力途中のテキスト"])
        XCTAssertTrue(window.firstResponder === editor, "Background saving must not end typing or IME composition")
        XCTAssertTrue(document.state.annotations.isEmpty, "A disk snapshot must not commit the live input into undo history")
        XCTAssertFalse(document.canUndo)

        editor.insertText("を続ける", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        try controller.autosaveNow()
        let latest = try restoredDocument(in: root, id: XCTUnwrap(draftID))
        XCTAssertEqual(latest.state.annotations.map(\.text), ["入力途中のテキストを続ける"])
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(latest.state.annotations.first?.id, restored.state.annotations.first?.id,
                       "Typing into one live annotation must retain its identity across autosaves")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(document.canUndo)
    }

    @MainActor
    func testWindowCloseFlushesLiveTextBeforeDebounceAndRestoresFromDisk() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let document = try XCTUnwrap(EditorDocument(image: image()))
        var draftID: UUID?
        var closeCount = 0
        var doneCount = 0
        let controller = EditorWindowController(document: document, title: "Close draft", onSave: { _ in doneCount += 1 },
            onAutosave: { image in
                draftID = try self.persist(document, image: image, in: library, replacing: draftID).id
            }, autosaveDelay: 60, onClose: { closeCount += 1 })
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        _ = try beginText(in: window, document: document, text: "完了を押さずに閉じる")
        XCTAssertNil(draftID)

        // AppKit asks the delegate before the red close button destroys the editor.
        XCTAssertTrue(controller.windowShouldClose(window))
        window.close()

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(doneCount, 0)
        XCTAssertEqual(document.state.annotations.map(\.text), ["完了を押さずに閉じる"])
        let restored = try restoredDocument(in: root, id: XCTUnwrap(draftID))
        XCTAssertEqual(restored.state.annotations.map(\.text), ["完了を押さずに閉じる"])
        XCTAssertEqual(library.items.count, 1)
    }

    @MainActor
    func testApplicationQuitFlushesEveryOpenEditorIncludingUncommittedText() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let first = try XCTUnwrap(EditorDocument(image: image()))
        let second = try XCTUnwrap(EditorDocument(image: image()))
        var firstID: UUID?
        var secondID: UUID?
        let firstWindow = EditorWindow.open(sessionID: UUID(), document: first, title: "First draft", onSave: { _ in },
            onAutosave: { image in
                firstID = try self.persist(first, image: image, in: library, replacing: firstID).id
            }, autosaveDelay: 60, onClose: {})
        defer { firstWindow.close() }
        let arrow = EditorAnnotation(tool: .arrow, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 70)], color: .red, width: 4)
        first.add(arrow)
        let secondWindow = EditorWindow.open(sessionID: UUID(), document: second, title: "Second draft", onSave: { _ in },
            onAutosave: { image in
                secondID = try self.persist(second, image: image, in: library, replacing: secondID).id
            }, autosaveDelay: 60, onClose: {})
        defer { secondWindow.close() }
        _ = try beginText(in: secondWindow, document: second, text: "終了直前の入力")

        try EditorWindow.flushAutosaves()

        let restoredArrow = try restoredDocument(in: root, id: XCTUnwrap(firstID))
        let restoredText = try restoredDocument(in: root, id: XCTUnwrap(secondID))
        XCTAssertEqual(restoredArrow.state.annotations.map(\.id), [arrow.id])
        XCTAssertEqual(restoredArrow.state.annotations.first?.points, arrow.points)
        XCTAssertEqual(restoredText.state.annotations.map(\.text), ["終了直前の入力"])
        XCTAssertEqual(try LibraryStore(root: root).items.count, 2)
        XCTAssertTrue(firstWindow.isVisible)
        XCTAssertTrue(secondWindow.isVisible)
    }

    @MainActor
    func testDebounceCoalescesRapidEditsAndDoesNotWriteAnUnchangedDocument() async throws {
        _ = NSApplication.shared
        let document = try XCTUnwrap(EditorDocument(image: image()))
        let saved = expectation(description: "Debounced autosave")
        var savedPadding: [Int] = []
        let controller = EditorWindowController(document: document, title: "Coalesce", onSave: { _ in },
            onAutosave: { _ in
                savedPadding.append(document.autosaveSnapshot.padding)
                saved.fulfill()
            }, autosaveDelay: 0.08, onClose: {})
        defer { controller.window?.close() }
        try controller.autosaveNow()
        XCTAssertTrue(savedPadding.isEmpty, "Merely opening an image must not create a draft")
        document.setPadding(12)
        document.setPadding(24)
        document.setPadding(48)

        await fulfillment(of: [saved], timeout: 2)

        XCTAssertEqual(savedPadding, [48])
        try controller.autosaveNow()
        try controller.flushAutosave()
        XCTAssertEqual(savedPadding, [48], "A clean flush must not duplicate history or rewrite a draft")
    }

    @MainActor
    func testFailedAutosaveKeepsDirtyEditsAndRetriesTheSameState() throws {
        _ = NSApplication.shared
        let document = try XCTUnwrap(EditorDocument(image: image()))
        var attempts = 0
        var shouldFail = true
        var persistedPadding: [Int] = []
        let controller = EditorWindowController(document: document, title: "Retry draft", onSave: { _ in },
            onAutosave: { _ in
                attempts += 1
                if shouldFail { throw NSError(domain: "EditorAutosaveTests", code: 1) }
                persistedPadding.append(document.autosaveSnapshot.padding)
            }, autosaveDelay: 60, onClose: {})
        defer { controller.window?.close() }
        document.setPadding(36)

        XCTAssertThrowsError(try controller.flushAutosave())
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(document.state.padding, 36)
        XCTAssertTrue(document.canUndo)
        shouldFail = false
        try controller.flushAutosave()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(persistedPadding, [36])
        try controller.flushAutosave()
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testTimerFailureDisplaysAutosaveStatusAndRemainsRetryable() async throws {
        _ = NSApplication.shared
        let document = try XCTUnwrap(EditorDocument(image: image()))
        let failed = expectation(description: "Autosave attempted")
        var shouldFail = true
        var attempts = 0
        let controller = EditorWindowController(document: document, title: "Failure status", onSave: { _ in },
            onAutosave: { _ in
                attempts += 1
                if shouldFail {
                    failed.fulfill()
                    throw NSError(domain: "EditorAutosaveTests", code: 2)
                }
            }, autosaveDelay: 0.05, onClose: {})
        defer { controller.window?.close() }
        document.setPadding(24)

        await fulfillment(of: [failed], timeout: 2)

        XCTAssertTrue(document.autosaveStatus.contains("自動保存できません"), document.autosaveStatus)
        XCTAssertEqual(document.state.padding, 24)
        shouldFail = false
        try controller.autosaveNow()
        XCTAssertEqual(attempts, 2)
        try controller.autosaveNow()
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testUndoAndRedoAreAutosavedAsEditableSnapshots() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let document = try XCTUnwrap(EditorDocument(image: image()))
        var draftID: UUID?
        let controller = EditorWindowController(document: document, title: "Undo draft", onSave: { _ in },
            onAutosave: { image in
                draftID = try self.persist(document, image: image, in: library, replacing: draftID).id
            }, autosaveDelay: 60, onClose: {})
        defer { controller.window?.close() }
        let text = EditorAnnotation(tool: .text, points: [CGPoint(x: 20, y: 30)], color: .red,
                                    width: 3, text: "変更前", fontSize: 18)
        document.add(text)
        document.updateText("変更後", id: text.id)
        try controller.autosaveNow()
        XCTAssertEqual(try restoredDocument(in: root, id: XCTUnwrap(draftID)).state.annotations.first?.text, "変更後")

        document.undo()
        try controller.autosaveNow()
        XCTAssertEqual(try restoredDocument(in: root, id: XCTUnwrap(draftID)).state.annotations.first?.text, "変更前")
        document.redo()
        try controller.autosaveNow()
        let restored = try restoredDocument(in: root, id: XCTUnwrap(draftID))
        XCTAssertEqual(restored.state.annotations.first?.text, "変更後")
        XCTAssertEqual(restored.state.annotations.first?.id, text.id)
        XCTAssertEqual(library.items.count, 1)
    }

    @MainActor
    func testEscapeCancelsAnAlreadyAutosavedLiveAnnotation() throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root)
        let document = try XCTUnwrap(EditorDocument(image: image()))
        var draftID: UUID?
        let controller = EditorWindowController(document: document, title: "Cancel draft", onSave: { _ in },
            onAutosave: { image in
                draftID = try self.persist(document, image: image, in: library, replacing: draftID).id
            }, autosaveDelay: 60, onClose: {})
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let editor = try beginText(in: window, document: document, text: "取り消す入力")
        try controller.autosaveNow()
        XCTAssertEqual(try restoredDocument(in: root, id: XCTUnwrap(draftID)).state.annotations.count, 1)
        let canvas = try XCTUnwrap(window.contentView as? AnnotationCanvas)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)

        XCTAssertTrue(canvas.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try controller.autosaveNow()

        let restored = try restoredDocument(in: root, id: XCTUnwrap(draftID))
        XCTAssertTrue(restored.state.annotations.isEmpty, "Escape must not leave a canceled annotation in the persisted draft")
        XCTAssertTrue(document.state.annotations.isEmpty)
        XCTAssertFalse(document.canUndo)
        XCTAssertEqual(library.items.count, 1)
    }

    @MainActor
    private func beginText(in window: NSWindow, document: EditorDocument, text: String) throws -> NSTextView {
        document.tool = .text
        let canvas = AnnotationCanvas(document: document)
        window.contentView = canvas
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 300, y: 200),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText(text, replacementRange: editor.selectedRange())
        return editor
    }

    @MainActor
    private func persist(_ document: EditorDocument, image: NSImage, in library: LibraryStore,
                         replacing id: UUID?) throws -> CaptureItem {
        try library.saveDraft(image: image,
            project: EditorProject(document: document, sourceTitle: "Original", snapshot: document.autosaveSnapshot),
            title: "Original — 下書き", replacing: id)
    }

    @MainActor
    private func restoredDocument(in root: URL, id: UUID) throws -> EditorDocument {
        let restarted = try LibraryStore(root: root)
        let item = try XCTUnwrap(restarted.items.first { $0.id == id })
        XCTAssertEqual(item.isDraft, true)
        return try XCTUnwrap(restarted.editableProject(for: item)).restore()
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HSShot.EditorAutosaveTests.\(UUID().uuidString)")
    }

    private func image() -> NSImage {
        let context = EditorRenderer.context(width: 160, height: 120)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 160, height: 120))
    }
}
