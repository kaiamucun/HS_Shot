import AppKit
import XCTest
@testable import HSShot

final class EditorTests: XCTestCase {
    private func fixture(width: Int = 80, height: Int = 60) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testExportPreservesPhysicalPixelsWithCropAndPadding() throws {
        let result = try XCTUnwrap(EditorRenderer.render(base: fixture(width: 160, height: 120), annotations: [], crop: CGRect(x: 30, y: 20, width: 90, height: 70), padding: 12, background: .navy))
        XCTAssertEqual(result.width, 114)
        XCTAssertEqual(result.height, 94)
    }

    func testSolidRedactionExportsOpaqueBlackPixels() throws {
        let annotation = EditorAnnotation(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)], color: .clear, width: 1)
        let result = try XCTUnwrap(EditorRenderer.render(base: fixture(), annotations: [annotation], crop: nil, padding: 0, background: .transparent))
        let bitmap = NSBitmapImageRep(cgImage: result)
        let color = try XCTUnwrap(bitmap.colorAt(x: 35, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(color.redComponent, 0.01)
        XCTAssertLessThan(color.greenComponent, 0.01)
        XCTAssertLessThan(color.blueComponent, 0.01)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
    }

    func testRedactionRemainsOpaqueAfterLaterAnnotationsAndPNGRoundTrip() throws {
        let redaction = EditorAnnotation(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)], color: .clear, width: 1)
        let highlight = EditorAnnotation(tool: .highlight, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)], color: .white, width: 5)
        let result = try XCTUnwrap(EditorRenderer.render(base: fixture(), annotations: [redaction, highlight], crop: nil, padding: 0, background: .transparent))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        let color = try XCTUnwrap(decoded.colorAt(x: 35, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
    }

    func testCropUsesBottomLeftCoordinatesWithoutVerticalReversal() throws {
        let context = try XCTUnwrap(EditorRenderer.context(width: 80, height: 60))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 30))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 30, width: 80, height: 30))
        let source = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(EditorRenderer.render(base: source, annotations: [], crop: CGRect(x: 0, y: 0, width: 80, height: 25), padding: 0, background: .transparent))
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: output).colorAt(x: 40, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.99)
        XCTAssertLessThan(color.blueComponent, 0.01)
    }

    func testRendererRejectsEmptyCropAndExcessiveAllocation() {
        XCTAssertNil(EditorRenderer.render(base: fixture(), annotations: [], crop: CGRect(x: 200, y: 200, width: 10, height: 10), padding: 0, background: .transparent))
        XCTAssertNil(EditorRenderer.context(width: 32_768, height: 32_768))
    }


    func testDocumentPreservesRetinaPixelsAndUndoRedoRestoresState() throws {
        try MainActor.assumeIsolated {
            let image = NSImage(cgImage: fixture(width: 160, height: 120), size: NSSize(width: 80, height: 60))
            let document = try XCTUnwrap(EditorDocument(image: image))
            let output = try XCTUnwrap(document.exportedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(output.width, 160)
            XCTAssertEqual(output.height, 120)
            document.crop(to: CGRect(x: 10, y: 10, width: 50, height: 40))
            XCTAssertTrue(document.canUndo)
            XCTAssertEqual(document.state.crop?.size, CGSize(width: 50, height: 40))
            document.undo()
            XCTAssertNil(document.state.crop)
            XCTAssertTrue(document.canRedo)
            document.redo()
            XCTAssertEqual(document.state.crop?.size, CGSize(width: 50, height: 40))
        }
    }

    func testInlineTextEnterCommitsAndEscapeCancels() throws {
        try MainActor.assumeIsolated {
            let document = try XCTUnwrap(EditorDocument(image: NSImage(cgImage: fixture(), size: NSSize(width: 80, height: 60))))
            document.tool = .text
            let canvas = AnnotationCanvas(document: document)
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 200, y: 200), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            canvas.mouseDown(with: event)
            let field = try XCTUnwrap(canvas.subviews.first as? NSTextField)
            field.stringValue = "大切な注釈"
            XCTAssertTrue(canvas.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(document.state.annotations.map(\.text), ["大切な注釈"])
            canvas.mouseDown(with: event)
            let cancelled = try XCTUnwrap(canvas.subviews.first as? NSTextField)
            cancelled.stringValue = "取り消す文字"
            XCTAssertTrue(canvas.control(cancelled, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            XCTAssertEqual(document.state.annotations.count, 1)
            XCTAssertTrue(canvas.subviews.isEmpty)
        }
    }


    func testMoveAndDeleteAnnotationsAreUndoableAndRenderAtNewPosition() throws {
        try MainActor.assumeIsolated {
            let document = try XCTUnwrap(EditorDocument(image: NSImage(cgImage: fixture(), size: NSSize(width: 80, height: 60))))
            let annotation = EditorAnnotation(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40)], color: .black, width: 2)
            document.add(annotation)
            document.select(annotation.id)
            document.moveSelected(by: CGPoint(x: 30, y: 0))
            XCTAssertEqual(document.state.annotations.first?.points.first, CGPoint(x: 40, y: 10))
            let output = try XCTUnwrap(document.exportedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: output)
            let previous = try XCTUnwrap(bitmap.colorAt(x: 20, y: 35)?.usingColorSpace(.deviceRGB))
            let moved = try XCTUnwrap(bitmap.colorAt(x: 50, y: 35)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(previous.redComponent, 0.9)
            XCTAssertLessThan(moved.redComponent, 0.01)
            document.undo()
            XCTAssertEqual(document.state.annotations.first?.points.first, CGPoint(x: 10, y: 10))
            document.redo()
            XCTAssertEqual(document.state.annotations.first?.points.first, CGPoint(x: 40, y: 10))
            document.removeSelected()
            XCTAssertTrue(document.state.annotations.isEmpty)
            document.undo()
            XCTAssertEqual(document.state.annotations.count, 1)
        }
    }


    func testFailedLibrarySavePropagatesFailureWithoutSuccessStatus() throws {
        try MainActor.assumeIsolated {
            let document = try XCTUnwrap(EditorDocument(image: NSImage(cgImage: fixture(), size: NSSize(width: 80, height: 60))))
            let originalStatus = document.status
            var callbackCount = 0
            XCTAssertThrowsError(try document.saveToLibrary { _ in
                callbackCount += 1
                throw NSError(domain: "fixture-disk-full", code: 28)
            })
            XCTAssertEqual(callbackCount, 1)
            XCTAssertEqual(document.status, originalStatus)
            try document.saveToLibrary { _ in callbackCount += 1 }
            XCTAssertEqual(callbackCount, 2)
            XCTAssertTrue(document.status.contains("保存しました"))
        }
    }


    func testCanvasDragCreatesOneUndoStepAndDeleteIsUndoable() throws {
        try MainActor.assumeIsolated {
            let document = try XCTUnwrap(EditorDocument(image: NSImage(cgImage: fixture(), size: NSSize(width: 80, height: 60))))
            document.add(EditorAnnotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: .white, width: 2))
            let canvas = AnnotationCanvas(document: document)
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let scale = min(736.0 / 80, 536.0 / 60)
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: (800 - 80 * scale) / 2 + point.x * scale, y: (600 - 60 * scale) / 2 + point.y * scale), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 20, y: 20)))
            XCTAssertNotNil(document.selectedAnnotationID)
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 25, y: 20)))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 30, y: 20)))
            canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 30, y: 20)))
            XCTAssertEqual(try XCTUnwrap(document.state.annotations.first?.points.first?.x), 20, accuracy: 0.001)
            document.undo()
            XCTAssertEqual(try XCTUnwrap(document.state.annotations.first?.points.first?.x), 10, accuracy: 0.001)
            document.redo()
            let deletion = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51))
            canvas.keyDown(with: deletion)
            XCTAssertTrue(document.state.annotations.isEmpty)
            document.undo()
            XCTAssertEqual(document.state.annotations.count, 1)
        }
    }


    func testInlineTextReadsLiveFieldEditorInputWhenEnterCommits() throws {
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let document = try XCTUnwrap(EditorDocument(image: NSImage(cgImage: fixture(), size: NSSize(width: 80, height: 60))))
            document.tool = .text
            let canvas = AnnotationCanvas(document: document)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = canvas
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 200, y: 200), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            canvas.mouseDown(with: event)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertTrue(editor.isFieldEditor)
            editor.insertText("ここを確認", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(document.state.annotations.map(\.text), ["ここを確認"])
            XCTAssertEqual(document.status, "テキストを追加しました")
            canvas.mouseDown(with: event)
            let cancelled = try XCTUnwrap(window.firstResponder as? NSTextView)
            cancelled.insertText("取り消す文字", replacementRange: cancelled.selectedRange())
            cancelled.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertEqual(document.state.annotations.map(\.text), ["ここを確認"])
            XCTAssertTrue(canvas.subviews.isEmpty)
        }
    }

}
