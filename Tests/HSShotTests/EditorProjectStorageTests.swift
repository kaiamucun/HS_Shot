import XCTest
import AppKit
import ImageIO
@testable import HSShot

final class EditorProjectStorageTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hs-shot-project-\(UUID().uuidString)")
    }

    private func image() -> NSImage {
        let context = EditorRenderer.context(width: 320, height: 200)!
        context.setFillColor(NSColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 320, height: 200))
    }

    @MainActor private func document() -> EditorDocument {
        let document = EditorDocument(image: image())!
        document.add(EditorAnnotation(tool: .text, points: [CGPoint(x: 50, y: 60)],
                                      color: NSColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 0.8),
                                      width: 3, text: "再編集する文字", fontSize: 28))
        document.add(EditorAnnotation(tool: .arrow, points: [CGPoint(x: 80, y: 80), CGPoint(x: 220, y: 130)],
                                      color: NSColor(srgbRed: 0.1, green: 0.6, blue: 0.2, alpha: 1), width: 7))
        document.crop(to: CGRect(x: 20, y: 10, width: 280, height: 160))
        document.setPadding(24)
        document.change { $0.background = .gradient }
        return document
    }

    @MainActor
    func testProjectSurvivesNewStoreAndRestoresEditableObjectsWithoutFlattening() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let textID = document.state.annotations[0].id
        let arrowID = document.state.annotations[1].id
        let originalState = document.state
        let output = try XCTUnwrap(document.exportedImage())
        let item = try store.add(image: output, project: EditorProject(document: document, sourceTitle: "撮影"), title: "撮影 — 編集済み")

        let restartedStore = try LibraryStore(root: root)
        let persisted = try XCTUnwrap(restartedStore.items.first)
        let project = try XCTUnwrap(restartedStore.editableProject(for: persisted))
        let suiteName = "hs-shot-project-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = EditorPreferences(defaults: defaults)
        preferences.padding = 96
        let reopened = try project.restore(preferences: preferences)
        XCTAssertEqual(project.sourceTitle, "撮影")
        XCTAssertEqual(reopened.base.width, 320)
        XCTAssertEqual(reopened.base.height, 200)
        XCTAssertEqual(reopened.state.crop, originalState.crop)
        XCTAssertEqual(reopened.state.padding, 24)
        XCTAssertEqual(reopened.state.background, .gradient)
        XCTAssertEqual(reopened.state.annotations.map(\.id), [textID, arrowID])
        XCTAssertEqual(reopened.state.annotations.map(\.tool), [.text, .arrow])
        XCTAssertEqual(reopened.state.annotations[0].text, "再編集する文字")
        XCTAssertEqual(reopened.state.annotations[0].fontSize, 28)
        XCTAssertEqual(reopened.state.annotations[0].color.usingColorSpace(.sRGB)!.alphaComponent, 0.8, accuracy: 0.0001)
        XCTAssertEqual(reopened.state.annotations[1].width, 7)
        XCTAssertEqual(reopened.state.annotations[1].points, originalState.annotations[1].points)
        XCTAssertFalse(reopened.canUndo)
        XCTAssertEqual(item.width, 328)
        XCTAssertEqual(item.height, 208)
        XCTAssertEqual(reopened.exportedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, item.width)
        XCTAssertEqual(reopened.exportedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.height, item.height)

        reopened.updateText("再起動後に修正", id: textID)
        reopened.select(arrowID)
        reopened.moveSelectedEndpoint(1, to: CGPoint(x: 250, y: 150))
        let revised = try restartedStore.add(image: XCTUnwrap(reopened.exportedImage()),
                                             project: EditorProject(document: reopened, sourceTitle: project.sourceTitle),
                                             title: "撮影 — 編集済み")
        let anotherStore = try LibraryStore(root: root)
        let secondDocument = try XCTUnwrap(anotherStore.editableProject(for: revised)).restore()
        XCTAssertEqual(secondDocument.state.annotations[0].text, "再起動後に修正")
        XCTAssertEqual(secondDocument.state.annotations[1].points.last, CGPoint(x: 250, y: 150))
        XCTAssertEqual(secondDocument.state.annotations.map(\.id), [textID, arrowID])
        XCTAssertEqual(secondDocument.base.width, 320)
        XCTAssertEqual(secondDocument.state.padding, 24)
        XCTAssertEqual(try XCTUnwrap(anotherStore.editableProject(for: item)).restore().state.annotations[0].text, "再編集する文字")
    }

    @MainActor
    func testDeletingOriginalKeepsIndependentProjectAndDeletingProjectRemovesItsFiles() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let original = try store.add(image: image(), title: "撮影")
        let document = document()
        let project = try EditorProject(document: document, sourceTitle: original.title)
        let edited = try store.add(image: XCTUnwrap(document.exportedImage()), project: project, title: "編集済み")
        let other = try store.add(image: XCTUnwrap(document.exportedImage()), project: project, title: "別の編集")
        try store.delete(original.id)
        let restart = try LibraryStore(root: root)
        XCTAssertEqual(try XCTUnwrap(restart.editableProject(for: edited)).restore().state.annotations.count, 2)
        try restart.delete(edited.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restart.url(for: edited).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restart.editableProjectURL(for: edited).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restart.url(for: other).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restart.editableProjectURL(for: other).path))
        XCTAssertEqual(try LibraryStore(root: root).items.map(\.id), [other.id])
    }

    @MainActor
    func testIndexFailureRollsBackBothNewFilesAndKeepsExistingHistory() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let original = try store.add(image: image(), title: "撮影")
        let index = root.appendingPathComponent("library.json")
        let oldIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let document = document()
        XCTAssertThrowsError(try store.add(image: XCTUnwrap(document.exportedImage()),
                                          project: EditorProject(document: document, sourceTitle: original.title), title: "編集済み"))
        XCTAssertEqual(store.items.map(\.id), [original.id])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set([original.filename, "library.json"]))
        try FileManager.default.removeItem(at: index)
        try oldIndex.write(to: index)
        XCTAssertEqual(try LibraryStore(root: root).items.map(\.id), [original.id])
    }

    @MainActor
    func testOldImageIndexRemainsReadableAndNeverClaimsEditableLayers() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let item = try store.add(image: image(), title: "旧バージョンの画像")
        let index = root.appendingPathComponent("library.json")
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        entries[0].removeValue(forKey: "editableProjectVersion")
        try JSONSerialization.data(withJSONObject: entries).write(to: index)
        let restart = try LibraryStore(root: root)
        let restored = try XCTUnwrap(restart.items.first)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertNil(restored.editableProjectVersion)
        XCTAssertNil(try restart.editableProject(for: restored))
    }

    @MainActor
    func testMissingCorruptAndFutureProjectsFailExplicitlyWithoutChangingImage() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let item = try store.add(image: XCTUnwrap(document.exportedImage()),
                                 project: EditorProject(document: document, sourceTitle: "撮影"), title: "編集")
        let sidecar = store.editableProjectURL(for: item)
        let png = try Data(contentsOf: store.url(for: item))
        try FileManager.default.removeItem(at: sidecar)
        XCTAssertThrowsError(try store.editableProject(for: item)) { error in
            guard case EditorProjectError.missingData = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try Data("broken".utf8).write(to: sidecar)
        XCTAssertThrowsError(try store.editableProject(for: item)) { error in
            guard case EditorProjectError.invalidData = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try Data("{\"schemaVersion\":2,\"newFormat\":true}".utf8).write(to: sidecar)
        XCTAssertThrowsError(try store.editableProject(for: item)) { error in
            guard case EditorProjectError.unsupportedVersion(2) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        var futureItem = item
        futureItem.editableProjectVersion = 2
        XCTAssertThrowsError(try store.editableProject(for: futureItem)) { error in
            guard case EditorProjectError.unsupportedVersion(2) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: store.url(for: item)), png)
        XCTAssertEqual(try LibraryStore(root: root).items.map(\.id), [item.id])
    }

    @MainActor
    func testMalformedSnapshotAndBaseAreRejected() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let item = try store.add(image: XCTUnwrap(document.exportedImage()),
                                 project: EditorProject(document: document, sourceTitle: "撮影"), title: "編集")
        let sidecar = store.editableProjectURL(for: item)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        var bad = original
        var snapshot = try XCTUnwrap(bad["snapshot"] as? [String: Any])
        snapshot["padding"] = -1
        bad["snapshot"] = snapshot
        try JSONSerialization.data(withJSONObject: bad).write(to: sidecar)
        XCTAssertThrowsError(try store.editableProject(for: item))
        bad = original
        bad["basePNG"] = Data("not an image".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: bad).write(to: sidecar)
        XCTAssertThrowsError(try store.editableProject(for: item))
        bad = original
        snapshot = try XCTUnwrap(bad["snapshot"] as? [String: Any])
        var annotations = try XCTUnwrap(snapshot["annotations"] as? [[String: Any]])
        annotations[1]["id"] = annotations[0]["id"]
        snapshot["annotations"] = annotations
        bad["snapshot"] = snapshot
        try JSONSerialization.data(withJSONObject: bad).write(to: sidecar)
        XCTAssertThrowsError(try store.editableProject(for: item))
    }

    @MainActor
    func testSharedPNGContainsFlattenedPixelsOnlyAndNoProjectPayload() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let document = document()
        let item = try store.add(image: XCTUnwrap(document.exportedImage()),
                                 project: EditorProject(document: document, sourceTitle: "非共有の元画像"), title: "編集")
        let sharedURL = store.url(for: item)
        let data = try Data(contentsOf: sharedURL)
        XCTAssertEqual(sharedURL.pathExtension, "png")
        XCTAssertNotEqual(sharedURL, store.editableProjectURL(for: item))
        XCTAssertNil(data.range(of: Data("basePNG".utf8)))
        XCTAssertNil(data.range(of: Data("非共有の元画像".utf8)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 328)
        XCTAssertEqual(image.height, 208)
        let localProjectBytes = try Data(contentsOf: store.editableProjectURL(for: item)).count
        XCTAssertEqual(item.byteCount, Int64(data.count + localProjectBytes))
    }
}
