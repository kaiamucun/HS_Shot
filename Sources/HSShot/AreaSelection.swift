import AppKit
import ScreenCaptureKit

enum AreaSelectionGeometry {
    /// Selection coordinates have their origin at the display's top left, like CGImage pixels.
    static func pixelRect(from start: CGPoint, to end: CGPoint, pointSize: CGSize, pixelSize: CGSize) -> CGRect? {
        let values = [start.x, start.y, end.x, end.y, pointSize.width, pointSize.height, pixelSize.width, pixelSize.height]
        guard values.allSatisfy(\.isFinite), pointSize.width > 0, pointSize.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(CGRect(origin: .zero, size: pointSize))
        guard !selection.isNull, selection.width > 0, selection.height > 0 else { return nil }
        let scaleX = pixelSize.width / pointSize.width
        let scaleY = pixelSize.height / pointSize.height
        let left = floor(selection.minX * scaleX), top = floor(selection.minY * scaleY)
        let right = min(pixelSize.width, ceil(selection.maxX * scaleX))
        let bottom = min(pixelSize.height, ceil(selection.maxY * scaleY))
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func crop(_ image: CGImage, from start: CGPoint, to end: CGPoint, pointSize: CGSize) -> CGImage? {
        guard let rect = pixelRect(from: start, to: end, pointSize: pointSize, pixelSize: CGSize(width: image.width, height: image.height)) else { return nil }
        return image.cropping(to: rect)
    }
}

/// Freeze displays before presenting our own selector. Each display keeps its native
/// pixel scale, and a selection belongs to the display on which the drag starts.
@MainActor
final class AreaSelectionSession {
    struct DisplaySnapshot {
        let frame: CGRect
        let image: CGImage
    }

    private let snapshots: [DisplaySnapshot]
    private var panels: [AreaSelectionPanel] = []
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var keyMonitor: Any?

    init(snapshots: [DisplaySnapshot]) { self.snapshots = snapshots }

    static func freezeDisplays() async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var snapshots: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            try Task.checkCancellation()
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            configuration.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots.append(DisplaySnapshot(frame: screen.frame, image: image))
        }
        guard !snapshots.isEmpty else { throw CaptureError.failed("撮影できるディスプレイが見つかりませんでした。") }
        return snapshots
    }

    func select() async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { self?.finish(nil); return nil }
                    return event
                }
                for snapshot in snapshots {
                    let panel = AreaSelectionPanel(contentRect: snapshot.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.title = "範囲を選択 — HS Shot"
                    panel.isReleasedWhenClosed = false
                    panel.level = .screenSaver
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                    panel.hidesOnDeactivate = false
                    panel.isOpaque = true
                    panel.backgroundColor = .white
                    panel.hasShadow = false
                    panel.contentView = AreaSelectionView(snapshot: snapshot) { [weak self] image in self?.finish(image) }
                    panels.append(panel)
                }
                NSApp.activate(ignoringOtherApps: true)
                panels.forEach { $0.orderFrontRegardless() }
                let activePanel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first
                activePanel?.makeKey()
                activePanel?.makeFirstResponder(activePanel?.contentView)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(nil) }
        }
    }

    private func finish(_ image: CGImage?) {
        guard let continuation else { return }
        self.continuation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        continuation.resume(returning: image)
    }
}

private final class AreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class AreaSelectionView: NSView {
    private let snapshot: AreaSelectionSession.DisplaySnapshot
    private let backgroundImage: NSImage
    private let completion: (CGImage?) -> Void
    private var start: CGPoint?
    private var end: CGPoint?
    private let blue = NSColor(calibratedRed: 46 / 255, green: 110 / 255, blue: 221 / 255, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(snapshot: AreaSelectionSession.DisplaySnapshot, completion: @escaping (CGImage?) -> Void) {
        self.snapshot = snapshot
        self.backgroundImage = NSImage(cgImage: snapshot.image, size: snapshot.frame.size)
        self.completion = completion
        super.init(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("範囲を選択。ドラッグして撮影、Escでキャンセル")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let dim = NSBezierPath(rect: bounds)
        var selection: CGRect?
        if let start, let end {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                selection = rect
                dim.appendRect(rect)
                dim.windingRule = .evenOdd
            }
        }
        NSColor(calibratedWhite: 0, alpha: 0.16).setFill()
        dim.fill()
        if let selection {
            blue.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            if let start, let end, let pixels = AreaSelectionGeometry.pixelRect(from: start, to: end, pointSize: bounds.size, pixelSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)) {
                drawPill("\(Int(pixels.width)) × \(Int(pixels.height)) px", centerX: selection.midX, top: min(bounds.height - 44, selection.maxY + 10))
            }
        } else {
            drawPill("ドラッグして範囲を選択   ·   Escでキャンセル", centerX: bounds.midX, top: 34)
        }
    }

    private func drawPill(_ text: String, centerX: CGFloat, top: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(calibratedRed: 38 / 255, green: 51 / 255, blue: 73 / 255, alpha: 1)]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = size.width + 30
        let rect = CGRect(x: max(8, min(bounds.width - width - 8, centerX - width / 2)), y: top, width: width, height: 36)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 15, y: rect.minY + (36 - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        end = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        end = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        completion(AreaSelectionGeometry.crop(snapshot.image, from: start, to: end, pointSize: bounds.size))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) } else { super.keyDown(with: event) }
    }
}
