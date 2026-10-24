import AppKit
import XCTest
@testable import HSShot

final class EditorPreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "HSShot.EditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
    private func image() -> NSImage {
        let context = EditorRenderer.context(width: 80, height: 60)!
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 80, height: 60))
    }

    func testPreferencesSurviveNewEditorsAndSelectionDoesNotOverwriteDefaults() throws {
        try MainActor.assumeIsolated {
            try withDefaults { defaults in
                let document = try XCTUnwrap(EditorDocument(image: image(), preferences: EditorPreferences(defaults: defaults)))
                XCTAssertEqual(document.lineWidth, 5)
                XCTAssertEqual(document.fontSize, 35)
                XCTAssertEqual(document.state.padding, 0)
                document.setColor(.systemOrange)
                document.setLineWidth(12)
                document.setFontSize(48)
                document.setPadding(32)
                let original = EditorAnnotation(tool: .text, points: [.zero], color: .white, width: 2, text: "選択", fontSize: 24)
                document.add(original)
                document.select(original.id)
                XCTAssertTrue(document.inspectorColor.isEqual(NSColor.white))
                XCTAssertEqual(document.inspectorLineWidth, 2)
                XCTAssertEqual(document.inspectorFontSize, 24)
                let reopened = try XCTUnwrap(EditorDocument(image: image(), preferences: EditorPreferences(defaults: defaults)))
                XCTAssertTrue(reopened.color.isEqual(NSColor.systemOrange.usingColorSpace(.sRGB)!))
                XCTAssertEqual(reopened.lineWidth, 12)
                XCTAssertEqual(reopened.fontSize, 48)
                XCTAssertEqual(reopened.state.padding, 32)
                reopened.setPadding(64)
                document.undo()
                XCTAssertEqual(document.state.padding, 32)
                XCTAssertEqual(EditorPreferences(defaults: defaults).padding, 64, "Undoing an annotation must not replace another editor's remembered padding")
                document.undo()
                XCTAssertEqual(document.state.padding, 0)
                document.redo()
                XCTAssertEqual(document.state.padding, 32)
            }
        }
    }

    func testSelectedStyleChangesUndoIndependentlyAndFontDoesNotFollowWidth() throws {
        try MainActor.assumeIsolated {
            let document = try XCTUnwrap(EditorDocument(image: image()))
            let annotation = EditorAnnotation(tool: .text, points: [.zero], color: .white, width: 5, text: "文字", fontSize: 35)
            document.add(annotation)
            document.select(annotation.id)
            let originalBounds = try XCTUnwrap(document.selectedAnnotation?.selectionBounds)
            document.setLineWidth(15)
            XCTAssertEqual(document.selectedAnnotation?.fontSize, 35)
            XCTAssertEqual(document.selectedAnnotation?.selectionBounds, originalBounds)
            document.setFontSize(60)
            XCTAssertEqual(document.selectedAnnotation?.width, 15)
            XCTAssertGreaterThan(try XCTUnwrap(document.selectedAnnotation?.selectionBounds.width), originalBounds.width)
            document.setColor(.black)
            XCTAssertTrue(try XCTUnwrap(document.selectedAnnotation?.color).isEqual(NSColor.black))
            document.undo()
            XCTAssertTrue(try XCTUnwrap(document.selectedAnnotation?.color).isEqual(NSColor.white))
            document.undo()
            XCTAssertEqual(document.selectedAnnotation?.fontSize, 35)
            document.undo()
            XCTAssertEqual(document.selectedAnnotation?.width, 5)
            document.redo()
            document.redo()
            document.redo()
            XCTAssertEqual(document.selectedAnnotation?.fontSize, 60)
            XCTAssertEqual(document.selectedAnnotation?.width, 15)
            XCTAssertEqual(document.selectedAnnotation?.id, annotation.id)
        }
    }

    func testInvalidStoredPreferencesFallbackOrClampSafely() throws {
        try MainActor.assumeIsolated {
            try withDefaults { defaults in
                defaults.set(-90, forKey: "editor.lineWidth")
                defaults.set(Double.infinity, forKey: "editor.fontSize")
                defaults.set(999_999, forKey: "editor.padding")
                defaults.set([1.0, 0.0], forKey: "editor.color")
                let document = try XCTUnwrap(EditorDocument(image: image(), preferences: EditorPreferences(defaults: defaults)))
                XCTAssertEqual(document.lineWidth, 1)
                XCTAssertEqual(document.fontSize, 35)
                XCTAssertEqual(document.state.padding, 1024)
                XCTAssertTrue(document.color.isEqual(NSColor(ShotTheme.accent)))
                document.setLineWidth(.nan)
                document.setFontSize(-40)
                document.setPadding(-1)
                XCTAssertEqual(document.lineWidth, 5)
                XCTAssertEqual(document.fontSize, 12)
                XCTAssertEqual(document.state.padding, 0)
            }
        }
    }
}
