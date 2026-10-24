import AppKit
import XCTest
@testable import HSShot

final class DraftStorageTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hs-shot-drafts-\(UUID().uuidString)")
    }

    private func image() -> NSImage {
        let context = EditorRenderer.context(width: 320, height: 200)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 320, height: 200))
    }

    @MainActor private func document() -> EditorDocument {
        let document = EditorDocument(image: image())!
        document.add(EditorAnnotation(tool: .text, points: [CGPoint(x: 20, y: 40)],
                                      color: .systemRed, width: 3, text: "最初の下書き", fontSize: 24))
        document.add(EditorAnnotation(tool: .arrow, points: [CGPoint(x: 90, y: 90), CGPoint(x: 220, y: 130)],
                                      color: .systemGreen, width: 5))
        document.setPadding(24)
        return document
    }

    @MainActor private func save(_ document: EditorDocument, in store: LibraryStore,
                                 replacing id: UUID? = nil) throws -> CaptureItem {
        try store.saveDraft(image: XCTUnwrap(document.exportedImage()),
                            project: EditorProject(document: document, sourceTitle: "元の撮影"),
                            title: "元の撮影 — 下書き", replacing: id)
    }

    private func files(in root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]).compactMap { url in
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return (url.lastPathComponent, try Data(contentsOf: url))
        })
    }

    @MainActor
    func testRepeatedAutosaveKeepsOneHistoryItemAndRestoresLatestEditableState() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let original = try store.add(image: image(), title: "元の撮影")
        let originalBytes = try Data(contentsOf: store.url(for: original))
        let document = document()
        let first = try save(document, in: store)
        try store.toggleFavorite(first.id)
        let textID = document.state.annotations[0].id
        let arrowID = document.state.annotations[1].id
        document.updateText("入力途中も復元", id: textID)
        document.select(arrowID)
        document.moveSelectedEndpoint(1, to: CGPoint(x: 280, y: 160))
        let second = try save(document, in: store, replacing: first.id)
        let third = try save(document, in: store, replacing: second.id)
        XCTAssertEqual(first.id, third.id)
        XCTAssertEqual(first.createdAt, third.createdAt)
        XCTAssertNotEqual(first.filename, second.filename)
        XCTAssertNotEqual(second.filename, third.filename)
        XCTAssertTrue(third.isFavorite)
        XCTAssertEqual(third.isDraft, true)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.editableProjectURL(for: second).path))
        XCTAssertEqual(try Data(contentsOf: store.url(for: original)), originalBytes)

        let restarted = try LibraryStore(root: root)
        let restoredItem = try XCTUnwrap(restarted.items.first(where: { $0.id == first.id }))
        let restored = try XCTUnwrap(restarted.editableProject(for: restoredItem)).restore()
        XCTAssertEqual(restored.state.annotations.map(\.id), [textID, arrowID])
        XCTAssertEqual(restored.state.annotations[0].text, "入力途中も復元")
        XCTAssertEqual(restored.state.annotations[1].points.last, CGPoint(x: 280, y: 160))
        XCTAssertEqual(restored.state.padding, 24)
        XCTAssertEqual(restored.base.width, 320)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       Set(["library.json", original.filename, third.filename,
                            store.editableProjectURL(for: third).lastPathComponent]))
    }

    @MainActor
    func testFailedReplacementPreservesCurrentGenerationAndRollsBackNewFiles() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let first = try save(document, in: store)
        let before = try files(in: root)
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        document.updateText("保存に失敗する変更", id: document.state.annotations[0].id)
        XCTAssertThrowsError(try save(document, in: store, replacing: first.id))
        XCTAssertEqual(store.items, [first])
        var withoutIndex = before
        withoutIndex.removeValue(forKey: "library.json")
        XCTAssertEqual(try files(in: root), withoutIndex)
        XCTAssertEqual(try XCTUnwrap(store.editableProject(for: first)).restore().state.annotations[0].text,
                       "最初の下書き")
        try FileManager.default.removeItem(at: index)
        try XCTUnwrap(before["library.json"]).write(to: index)
        XCTAssertEqual(try LibraryStore(root: root).items, [first])
        let retried = try save(document, in: store, replacing: first.id)
        XCTAssertEqual(retried.id, first.id)
        XCTAssertEqual(try XCTUnwrap(store.editableProject(for: retried)).restore().state.annotations[0].text,
                       "保存に失敗する変更")
    }

    @MainActor
    func testFailedFirstAutosaveDoesNotLeaveOrphanImagesOrProjects() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let original = try store.add(image: image(), title: "元の撮影")
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try save(document(), in: store))
        XCTAssertEqual(store.items, [original])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       Set(["library.json", original.filename]))
    }

    @MainActor
    func testPromotionFailureCanBeRetriedWithoutRewritingProjectOrImage() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let draft = try save(document(), in: store)
        let before = try files(in: root)
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.finalizeDraft(draft.id, title: "元の撮影 — 編集済み"))
        XCTAssertEqual(store.items, [draft])
        try FileManager.default.removeItem(at: index)
        try XCTUnwrap(before["library.json"]).write(to: index)
        let completed = try store.finalizeDraft(draft.id, title: "元の撮影 — 編集済み")
        XCTAssertEqual(completed.id, draft.id)
        XCTAssertEqual(completed.filename, draft.filename)
        XCTAssertNotEqual(completed.isDraft, true)
        XCTAssertEqual(completed.title, "元の撮影 — 編集済み")
        XCTAssertEqual(try Data(contentsOf: store.url(for: completed)), before[draft.filename])
        XCTAssertEqual(try Data(contentsOf: store.editableProjectURL(for: completed)),
                       before[store.editableProjectURL(for: draft).lastPathComponent])
        XCTAssertEqual(try LibraryStore(root: root).items, [completed])
    }

    @MainActor
    func testCompletedAndMissingEntriesCannotBeOverwrittenOrPromotedAsDrafts() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let completed = try store.add(image: XCTUnwrap(document.exportedImage()),
                                      project: EditorProject(document: document, sourceTitle: "元の撮影"), title: "完了済み")
        let before = try files(in: root)
        XCTAssertThrowsError(try save(document, in: store, replacing: completed.id))
        XCTAssertThrowsError(try save(document, in: store, replacing: UUID()))
        XCTAssertThrowsError(try store.finalizeDraft(completed.id, title: "上書き"))
        XCTAssertThrowsError(try store.finalizeDraft(UUID(), title: "存在しない"))
        XCTAssertEqual(try files(in: root), before)
        XCTAssertEqual(store.items, [completed])
    }

    @MainActor
    func testVersion120ProjectsWithoutDraftMarkerRemainEditable() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let completed = try store.add(image: XCTUnwrap(document.exportedImage()),
                                      project: EditorProject(document: document, sourceTitle: "既存"), title: "既存")
        XCTAssertEqual(completed.filename, "\(completed.id.uuidString).png")
        let index = root.appendingPathComponent("library.json")
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        entries[0].removeValue(forKey: "isDraft")
        try JSONSerialization.data(withJSONObject: entries).write(to: index)
        let restarted = try LibraryStore(root: root)
        let item = try XCTUnwrap(restarted.items.first)
        XCTAssertNil(item.isDraft)
        XCTAssertEqual(try XCTUnwrap(restarted.editableProject(for: item)).restore().state.annotations[0].text,
                       "最初の下書き")
    }

    @MainActor
    func testDeleteOnlyRemovesCurrentDraftGenerationAndPreservesOtherItems() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let first = try save(document, in: store)
        let draft = try save(document, in: store, replacing: first.id)
        let other = try save(document, in: store)
        let otherImage = try Data(contentsOf: store.url(for: other))
        let otherProject = try Data(contentsOf: store.editableProjectURL(for: other))
        try store.delete(draft.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: draft).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.editableProjectURL(for: draft).path))
        XCTAssertEqual(try Data(contentsOf: store.url(for: other)), otherImage)
        XCTAssertEqual(try Data(contentsOf: store.editableProjectURL(for: other)), otherProject)
        XCTAssertEqual(try LibraryStore(root: root).items, [other])
    }

    @MainActor
    func testUnownedFilenamesCannotBeUsedForDraftReplacementOrFileDeletion() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let draft = try save(document(), in: store)
        let unowned = root.appendingPathComponent("keep.png")
        try Data("do not delete".utf8).write(to: unowned)
        let index = root.appendingPathComponent("library.json")
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        entries[0]["filename"] = unowned.lastPathComponent
        try JSONSerialization.data(withJSONObject: entries).write(to: index)
        let restarted = try LibraryStore(root: root)
        XCTAssertThrowsError(try save(document(), in: restarted, replacing: draft.id))
        XCTAssertThrowsError(try restarted.editableProject(for: XCTUnwrap(restarted.items.first)))
        try restarted.delete(draft.id)
        XCTAssertEqual(try Data(contentsOf: unowned), Data("do not delete".utf8))
    }
}
