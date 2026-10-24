import AppKit
import Combine
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlight, text, number, pixelate, redact, crop
    var id: Self { self }
    var title: String {
        switch self {
        case .select: return "選択・移動"
        case .arrow: return "矢印"
        case .line: return "線"
        case .rectangle: return "四角形"
        case .ellipse: return "楕円"
        case .pen: return "ペン"
        case .highlight: return "ハイライト"
        case .text: return "テキスト"
        case .number: return "連番"
        case .pixelate: return "ピクセル化"
        case .redact: return "塗りつぶし秘匿"
        case .crop: return "切り抜き"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .number: return "1.circle"
        case .pixelate: return "square.grid.3x3.fill"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        }
    }
}

enum EditorBackground: String, CaseIterable, Identifiable {
    case transparent, navy, white, gradient
    var id: Self { self }
    var title: String {
        switch self {
        case .transparent: return "透明"
        case .navy: return "ネイビー"
        case .white: return "ホワイト"
        case .gradient: return "グラデーション"
        }
    }
}

struct EditorAnnotation: Identifiable {
    var id = UUID()
    var tool: EditorTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var fontSize: CGFloat = 35
    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
}

extension EditorTool {
    static func shortcut(_ key: String) -> EditorTool? {
        switch key {
        case "v": return .select
        case "a": return .arrow
        case "r": return .rectangle
        case "t": return .text
        case "b": return .pen
        case "h": return .highlight
        case "c": return .crop
        default: return nil
        }
    }
    var keyHint: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .text: return "T"
        case .pen: return "B"
        case .highlight: return "H"
        case .crop: return "C"
        default: return ""
        }
    }
}

extension EditorAnnotation {
    var selectionBounds: CGRect {
        guard let point = points.first else { return .zero }
        let fontSize = EditorPreferences.validFontSize(fontSize)
        if tool == .text {
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold)])
            return CGRect(origin: point, size: CGSize(width: max(1, size.width), height: max(1, size.height)))
        }
        if tool == .number {
            let radius = max(16, fontSize * 0.7)
            return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        }
        let minX = points.map(\.x).min() ?? point.x
        let maxX = points.map(\.x).max() ?? point.x
        let minY = points.map(\.y).min() ?? point.y
        let maxY = points.map(\.y).max() ?? point.y
        let inset: CGFloat = [.arrow, .line, .pen, .rectangle, .ellipse].contains(tool) ? max(1, width / 2) : 0
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)).insetBy(dx: -inset, dy: -inset)
    }
    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        guard selectionBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        guard [.arrow, .line, .pen].contains(tool), points.count > 1 else { return true }
        return zip(points, points.dropFirst()).contains { first, last in
            let dx = last.x - first.x, dy = last.y - first.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1, ((point.x - first.x) * dx + (point.y - first.y) * dy) / lengthSquared))
            return hypot(point.x - first.x - t * dx, point.y - first.y - t * dy) <= tolerance + width / 2
        }
    }
}

/// All coordinates and widths are physical image pixels in a bottom-left coordinate system.
/// Export draws only flattened pixels; the source image and editable shapes are never embedded.
enum EditorRenderer {
    static func render(base: CGImage, annotations: [EditorAnnotation], crop: CGRect?, padding: Int, background: EditorBackground) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let selection = (crop ?? bounds).integral.intersection(bounds)
        let inset = max(0, min(padding, 1024))
        guard !selection.isEmpty, let source = context(width: base.width, height: base.height) else { return nil }
        source.draw(base, in: bounds)
        for annotation in annotations where annotation.tool != .redact {
            draw(annotation, in: source, base: base)
        }
        // Redaction always runs last, with opaque black, independent of the selected color/opacity.
        for annotation in annotations where annotation.tool == .redact {
            source.saveGState()
            source.setBlendMode(.copy)
            source.setShouldAntialias(false)
            source.setFillColor(CGColor(gray: 0, alpha: 1))
            source.fill(annotation.rect.integral.intersection(bounds))
            source.restoreGState()
        }
        let cgCrop = CGRect(x: selection.minX, y: CGFloat(base.height) - selection.maxY, width: selection.width, height: selection.height)
        guard let flattened = source.makeImage()?.cropping(to: cgCrop),
              let output = context(width: Int(selection.width) + inset * 2, height: Int(selection.height) + inset * 2) else { return nil }
        drawBackground(background, in: output, bounds: CGRect(x: 0, y: 0, width: output.width, height: output.height))
        output.draw(flattened, in: CGRect(x: inset, y: inset, width: flattened.width, height: flattened.height))
        return output.makeImage()
    }

    static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              Int64(width) * Int64(height) <= 64_000_000 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func drawBackground(_ background: EditorBackground, in context: CGContext, bounds: CGRect) {
        switch background {
        case .transparent: return
        case .navy:
            context.setFillColor(NSColor(srgbRed: 0.055, green: 0.08, blue: 0.14, alpha: 1).cgColor)
            context.fill(bounds)
        case .white:
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
        case .gradient:
            let colors = [NSColor(srgbRed: 0.18, green: 0.19, blue: 0.45, alpha: 1).cgColor,
                          NSColor(srgbRed: 0.08, green: 0.5, blue: 0.48, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: bounds.minX, y: bounds.maxY), end: CGPoint(x: bounds.maxX, y: bounds.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
    }

    static func draw(_ annotation: EditorAnnotation, in context: CGContext, base: CGImage) {
        guard let first = annotation.points.first else { return }
        let last = annotation.points.last ?? first
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(max(1, annotation.width))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.tool {
        case .arrow, .line:
            context.move(to: first)
            context.addLine(to: last)
            context.strokePath()
            if annotation.tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(13, annotation.width * 4)
                context.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                context.addLine(to: last)
                context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                context.strokePath()
            }
        case .rectangle: context.stroke(annotation.rect)
        case .ellipse: context.strokeEllipse(in: annotation.rect)
        case .pen:
            context.move(to: first)
            for point in annotation.points.dropFirst() { context.addLine(to: point) }
            if annotation.points.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            context.strokePath()
        case .highlight:
            context.setFillColor(annotation.color.withAlphaComponent(0.32).cgColor)
            context.fill(annotation.rect)
        case .redact:
            context.setFillColor(NSColor.black.cgColor)
            context.fill(annotation.rect.integral)
        case .pixelate:
            let rect = annotation.rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
            let cgRect = CGRect(x: rect.minX, y: CGFloat(base.height) - rect.maxY, width: rect.width, height: rect.height)
            guard !rect.isEmpty, let image = base.cropping(to: cgRect),
                  let reduced = self.context(width: max(1, Int(rect.width / 14)), height: max(1, Int(rect.height / 14))) else { return }
            reduced.interpolationQuality = .medium
            reduced.draw(image, in: CGRect(x: 0, y: 0, width: reduced.width, height: reduced.height))
            if let mosaic = reduced.makeImage() {
                context.interpolationQuality = .none
                context.draw(mosaic, in: rect)
            }
        case .text, .number:
            let fontSize = EditorPreferences.validFontSize(annotation.fontSize)
            if annotation.tool == .number {
                let radius = max(16, fontSize * 0.7)
                context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: annotation.tool == .number ? NSColor.white : annotation.color
            ]
            let string = NSAttributedString(string: annotation.text, attributes: attributes)
            let size = string.size()
            let position = annotation.tool == .number ? CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2) : first
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(at: position)
            NSGraphicsContext.restoreGraphicsState()
        case .crop, .select: break
        }
    }
}

struct EditorSnapshot {
    var annotations: [EditorAnnotation] = []
    var crop: CGRect?
    var padding = 0
    var background: EditorBackground = .transparent
}

@MainActor
final class EditorDocument: ObservableObject {
    let base: CGImage
    @Published private(set) var selectedAnnotationID: UUID?
    @Published var tool: EditorTool = .select
    @Published private(set) var color: NSColor = NSColor(ShotTheme.accent)
    @Published private(set) var lineWidth: CGFloat = 5
    @Published private(set) var fontSize: CGFloat = 35
    @Published var text = "テキスト"
    @Published private(set) var state = EditorSnapshot()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var status = "ツールを選んで画像の上をドラッグ"
    private var undoStates: [EditorSnapshot] = []
    private var redoStates: [EditorSnapshot] = []
    private(set) var preview: CGImage
    private let preferences: EditorPreferences?

    init?(image: NSImage, preferences: EditorPreferences? = nil, restoredState: EditorSnapshot? = nil) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width <= 32_768, cgImage.height <= 32_768,
              Int64(cgImage.width) * Int64(cgImage.height) <= 64_000_000 else { return nil }
        base = cgImage
        preview = cgImage
        self.preferences = preferences
        if let preferences {
            color = preferences.color
            lineWidth = preferences.lineWidth
            fontSize = preferences.fontSize
            state.padding = preferences.padding
        }
        if let restoredState {
            state = restoredState
            refresh()
            status = "保存した編集を再開しました。文字や矢印を選んで調整できます"
        }
    }
    var dimensions: String {
        let size = state.crop?.size ?? CGSize(width: base.width, height: base.height)
        return "\(Int(size.width) + state.padding * 2) × \(Int(size.height) + state.padding * 2) px"
    }
    func change(_ body: (inout EditorSnapshot) -> Void) {
        undoStates.append(state)
        if undoStates.count > 80 { undoStates.removeFirst() }
        redoStates.removeAll()
        body(&state)
        refresh()
    }
    func add(_ annotation: EditorAnnotation) {
        change { $0.annotations.append(annotation) }
        status = "\(annotation.tool.title)を追加しました"
    }
    func crop(to rect: CGRect) {
        let bounded = rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard bounded.width >= 2, bounded.height >= 2 else { return }
        change { $0.crop = bounded }
        status = "切り抜き範囲を設定しました。書き出し時に適用されます"
    }
    func select(_ id: UUID?) { selectedAnnotationID = id }
    var inspectorColor: NSColor { selectedAnnotation?.color ?? color }
    var inspectorLineWidth: CGFloat { selectedAnnotation?.width ?? lineWidth }
    var inspectorFontSize: CGFloat { selectedAnnotation?.fontSize ?? fontSize }
    func setColor(_ value: NSColor) {
        color = value
        preferences?.color = value
        guard let selected = selectedAnnotation, !selected.color.isEqual(value) else { return }
        updateSelected { $0.color = value }
    }
    func setLineWidth(_ value: CGFloat) {
        let value = EditorPreferences.validLineWidth(value)
        lineWidth = value
        preferences?.lineWidth = value
        guard let selected = selectedAnnotation, selected.width != value else { return }
        updateSelected { $0.width = value }
    }
    func setFontSize(_ value: CGFloat) {
        let value = EditorPreferences.validFontSize(value)
        fontSize = value
        preferences?.fontSize = value
        guard let selected = selectedAnnotation, [.text, .number].contains(selected.tool), selected.fontSize != value else { return }
        updateSelected { $0.fontSize = value }
    }
    func setPadding(_ value: Int) {
        let value = max(0, min(1024, value))
        preferences?.padding = value
        guard state.padding != value else { return }
        change { $0.padding = value }
    }
    private func updateSelected(_ body: (inout EditorAnnotation) -> Void) {
        guard let index = state.annotations.firstIndex(where: { $0.id == selectedAnnotationID }) else { return }
        change { body(&$0.annotations[index]) }
        status = "選択した注釈のスタイルを変更しました。⌘Z で元に戻せます"
    }
    func updateText(_ text: String, id: UUID) {
        guard !text.isEmpty, let index = state.annotations.firstIndex(where: { $0.id == id && $0.tool == .text }),
              state.annotations[index].text != text else { return }
        change { $0.annotations[index].text = text }
        status = "テキストを修正しました。⌘Z で元に戻せます"
    }
    func moveSelectedEndpoint(_ index: Int, to point: CGPoint) {
        guard let selected = selectedAnnotation, [.arrow, .line].contains(selected.tool), selected.points.count == 2,
              (0...1).contains(index), point.x.isFinite, point.y.isFinite else { return }
        let point = CGPoint(x: max(0, min(CGFloat(base.width), point.x)), y: max(0, min(CGFloat(base.height), point.y)))
        let other = selected.points[1 - index]
        guard hypot(point.x - other.x, point.y - other.y) >= 1, point != selected.points[index] else { return }
        updateSelected { $0.points[index] = point }
        status = "端点を調整しました。⌘Z で元に戻せます"
    }
    func moveSelected(by offset: CGPoint) {
        guard let id = selectedAnnotationID, let index = state.annotations.firstIndex(where: { $0.id == id }),
              abs(offset.x) > 0.01 || abs(offset.y) > 0.01 else { return }
        change { $0.annotations[index].points = $0.annotations[index].points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) } }
        status = "注釈を移動しました"
    }
    func removeSelected() {
        guard let id = selectedAnnotationID, state.annotations.contains(where: { $0.id == id }) else { return }
        change { $0.annotations.removeAll { $0.id == id } }
        selectedAnnotationID = nil
        status = "注釈を削除しました。⌘Z で元に戻せます"
    }
    var selectedAnnotation: EditorAnnotation? {
        state.annotations.first { $0.id == selectedAnnotationID }
    }
    func annotation(at point: CGPoint, tolerance: CGFloat) -> EditorAnnotation? {
        let ordered = state.annotations.filter { $0.tool != .redact } + state.annotations.filter { $0.tool == .redact }
        return ordered.reversed().first { $0.contains(point, tolerance: tolerance) }
    }
    func undo() {
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(state)
        let paddingChanged = state.padding != previous.padding
        state = previous
        if paddingChanged { preferences?.padding = state.padding }
        refresh()
    }
    func redo() {
        guard let next = redoStates.popLast() else { return }
        undoStates.append(state)
        let paddingChanged = state.padding != next.padding
        state = next
        if paddingChanged { preferences?.padding = state.padding }
        refresh()
    }
    func exportedImage() -> NSImage? {
        guard let rendered = EditorRenderer.render(base: base, annotations: state.annotations, crop: state.crop, padding: state.padding, background: state.background) else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
    }
    func saveToLibrary(using callback: (NSImage) throws -> Void) throws {
        guard let image = exportedImage() else {
            throw NSError(domain: "HSShot.Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: "画像が大きすぎるため保存できませんでした。余白や切り抜き範囲を調整してください。"])
        }
        try callback(image)
        status = "編集した画像を新しい項目としてライブラリに保存しました"
    }
    private func refresh() {
        if let id = selectedAnnotationID, !state.annotations.contains(where: { $0.id == id }) { selectedAnnotationID = nil }
        preview = EditorRenderer.render(base: base, annotations: state.annotations, crop: nil, padding: 0, background: .transparent) ?? base
        canUndo = !undoStates.isEmpty
        canRedo = !redoStates.isEmpty
    }
}

@MainActor
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    var document: EditorDocument
    private var draft: EditorAnnotation?
    private var textEditor: NSTextField?
    private var textPoint: CGPoint?
    private var editingTextID: UUID?
    private var draggedEndpointIndex: Int?
    private var dragOrigin: CGPoint?
    private var dragOffset = CGPoint.zero
    private var draggedAnnotation: EditorAnnotation?
    private var movePreview: CGImage?
    override var acceptsFirstResponder: Bool { true }
    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var imageRect: CGRect {
        let padding = CGFloat(document.state.padding)
        let scale = max(0.001, min((bounds.width - 64) / (CGFloat(document.base.width) + padding * 2), (bounds.height - 64) / (CGFloat(document.base.height) + padding * 2)))
        let size = CGSize(width: CGFloat(document.base.width) * scale, height: CGFloat(document.base.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor(ShotTheme.canvas).setFill()
        bounds.fill()
        let rect = imageRect
        let scale = rect.width / CGFloat(document.base.width)
        let padding = CGFloat(document.state.padding) * scale
        let backdrop = rect.insetBy(dx: -padding, dy: -padding)
        // A quiet checkerboard makes alpha visible without affecting export pixels.
        context.saveGState()
        context.clip(to: backdrop)
        for y in stride(from: Int(backdrop.minY), through: Int(backdrop.maxY), by: 12) {
            for x in stride(from: Int(backdrop.minX), through: Int(backdrop.maxX), by: 12) {
                let light = ((x - Int(backdrop.minX)) / 12 + (y - Int(backdrop.minY)) / 12) % 2 == 0
                context.setFillColor(CGColor(gray: light ? 0.98 : 0.93, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 12, height: 12))
            }
        }
        EditorRenderer.drawBackground(document.state.background, in: context, bounds: backdrop)
        context.restoreGState()
        context.draw(movePreview ?? document.preview, in: rect)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        context.clip(to: CGRect(x: 0, y: 0, width: document.base.width, height: document.base.height))
        if let dragged = draggedPreviewAnnotation, movePreview != nil {
            EditorRenderer.draw(dragged, in: context, base: document.base)
        }
        if let draft, draft.tool != .crop { EditorRenderer.draw(draft, in: context, base: document.base) }
        if var selected = document.selectedAnnotation, document.tool == .select {
            selected = draggedPreviewAnnotation ?? selected
            context.setStrokeColor(NSColor(ShotTheme.accent).cgColor)
            context.setLineWidth(1.5 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale])
            context.stroke(selected.selectionBounds.insetBy(dx: -5 / scale, dy: -5 / scale))
            context.setLineDash(phase: 0, lengths: [])
            if [.arrow, .line].contains(selected.tool), selected.points.count == 2 {
                for point in selected.points {
                    let handle = CGRect(x: point.x - 5 / scale, y: point.y - 5 / scale, width: 10 / scale, height: 10 / scale)
                    context.setFillColor(NSColor.white.cgColor)
                    context.fillEllipse(in: handle)
                    context.strokeEllipse(in: handle)
                }
            }
        }
        if let crop = draft?.tool == .crop ? draft?.rect : document.state.crop {
            context.setFillColor(NSColor(ShotTheme.text).withAlphaComponent(0.3).cgColor)
            let full = CGRect(x: 0, y: 0, width: document.base.width, height: document.base.height)
            context.addRect(full)
            context.addRect(crop)
            context.drawPath(using: .eoFill)
            context.setStrokeColor(NSColor(ShotTheme.accent).cgColor)
            context.setLineWidth(2 / scale)
            context.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
            context.stroke(crop)
        }
        context.restoreGState()
    }
    private func imagePoint(_ event: NSEvent, clamp: Bool = true) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        let scale = rect.width / CGFloat(document.base.width)
        let x = (point.x - rect.minX) / scale
        let y = (point.y - rect.minY) / scale
        return CGPoint(x: clamp ? max(0, min(CGFloat(document.base.width), x)) : x,
                       y: clamp ? max(0, min(CGFloat(document.base.height), y)) : y)
    }
    override func mouseDown(with event: NSEvent) {
        let raw = imagePoint(event, clamp: false)
        let scale = imageRect.width / CGFloat(document.base.width)
        // A first click with the text tool opens a draft. A following double-click
        // on placed text must cancel that draft before opening the existing annotation.
        let editsExistingText = event.clickCount >= 2 && document.annotation(at: raw, tolerance: 7 / scale)?.tool == .text
        commitText(cancel: editsExistingText && editingTextID == nil)
        window?.makeFirstResponder(self)
        let endpoint = document.tool == .select ? selectedEndpoint(at: raw, tolerance: 9 / scale) : nil
        guard endpoint != nil || CGRect(x: 0, y: 0, width: document.base.width, height: document.base.height).contains(raw) else {
            document.select(nil)
            cancelMove()
            needsDisplay = true
            return
        }
        let point = imagePoint(event)
        let hit = document.annotation(at: point, tolerance: 7 / scale)
        if event.clickCount >= 2, let hit, hit.tool == .text {
            cancelMove()
            document.select(hit.id)
            document.tool = .select
            beginText(at: hit.points.first ?? point, annotation: hit)
            needsDisplay = true
            return
        }
        if document.tool == .select {
            let selected = endpoint != nil ? document.selectedAnnotation : hit
            document.select(selected?.id)
            draggedEndpointIndex = endpoint
            draggedAnnotation = selected
            dragOrigin = selected == nil ? nil : point
            dragOffset = .zero
            if let selected {
                movePreview = EditorRenderer.render(base: document.base, annotations: document.state.annotations.filter { $0.id != selected.id }, crop: nil, padding: 0, background: .transparent)
                document.status = Self.selectionHelp(for: selected)
            } else { movePreview = nil }
            needsDisplay = true
            return
        }
        document.select(nil)
        var annotation = EditorAnnotation(tool: document.tool, points: [point, point], color: document.color, width: document.lineWidth, fontSize: document.fontSize)
        if document.tool == .text {
            beginText(at: point)
        } else if document.tool == .number {
            annotation.text = String(document.state.annotations.filter { $0.tool == .number }.count + 1)
            document.add(annotation)
        } else {
            draft = annotation
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if let origin = dragOrigin, draggedAnnotation != nil {
            let point = imagePoint(event)
            dragOffset = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            needsDisplay = true
            return
        }
        guard var annotation = draft else { return }
        let point = imagePoint(event)
        if annotation.tool == .pen { annotation.points.append(point) } else { annotation.points[annotation.points.count - 1] = point }
        draft = annotation
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if draggedAnnotation != nil {
            if let index = draggedEndpointIndex, let moved = draggedPreviewAnnotation {
                document.moveSelectedEndpoint(index, to: moved.points[index])
            } else { document.moveSelected(by: dragOffset) }
            cancelMove()
            needsDisplay = true
            return
        }
        guard let annotation = draft else { return }
        draft = nil
        if annotation.tool == .crop { document.crop(to: annotation.rect) }
        else if annotation.tool == .pen || annotation.rect.width > 1 || annotation.rect.height > 1 { document.add(annotation) }
        needsDisplay = true
    }
    private func beginText(at point: CGPoint, annotation: EditorAnnotation? = nil) {
        let rect = imageRect
        let scale = rect.width / CGFloat(document.base.width)
        let origin = CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y, width: min(280, max(100, bounds.width - origin.x - 12)), height: 32))
        field.stringValue = annotation?.text ?? document.text
        field.placeholderString = "テキストを入力"
        let fontSize = (annotation?.fontSize ?? document.fontSize) * scale
        field.font = .systemFont(ofSize: max(14, fontSize), weight: .bold)
        field.frame.size.height = max(32, fontSize * 1.4)
        field.frame.size.width = min(max(280, field.attributedStringValue.size().width + 24), max(100, bounds.width - origin.x - 12))
        field.textColor = NSColor(ShotTheme.text)
        field.backgroundColor = NSColor(ShotTheme.panel)
        field.drawsBackground = true
        field.focusRingType = .none
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        textPoint = point
        editingTextID = annotation?.id
        textEditor = field
        addSubview(field)
        document.status = "テキストを入力：Enter で確定 / Esc で取消"
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    private func commitText(cancel: Bool = false) {
        guard let field = textEditor, let point = textPoint else { return }
        let text = (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        let existingID = editingTextID
        textEditor = nil
        textPoint = nil
        editingTextID = nil
        field.delegate = nil
        field.removeFromSuperview()
        if !cancel && !text.isEmpty {
            document.text = text
            if let existingID { document.updateText(text, id: existingID) }
            else { document.add(EditorAnnotation(tool: .text, points: [point], color: document.color, width: document.lineWidth, text: text, fontSize: document.fontSize)) }
        }
        needsDisplay = true
    }
    func controlTextDidEndEditing(_ notification: Notification) { commitText() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitText(cancel: true)
            window?.makeFirstResponder(self)
            document.status = "テキスト入力を取り消しました"
            return true
        }
        return false
    }
    private func selectedEndpoint(at point: CGPoint, tolerance: CGFloat) -> Int? {
        guard let annotation = document.selectedAnnotation, [.arrow, .line].contains(annotation.tool), annotation.points.count == 2 else { return nil }
        let closest = annotation.points.indices.min {
            hypot(annotation.points[$0].x - point.x, annotation.points[$0].y - point.y) < hypot(annotation.points[$1].x - point.x, annotation.points[$1].y - point.y)
        }
        return closest.flatMap { hypot(annotation.points[$0].x - point.x, annotation.points[$0].y - point.y) <= tolerance ? $0 : nil }
    }
    private var draggedPreviewAnnotation: EditorAnnotation? {
        guard var annotation = draggedAnnotation else { return nil }
        if let index = draggedEndpointIndex {
            annotation.points[index] = CGPoint(x: annotation.points[index].x + dragOffset.x, y: annotation.points[index].y + dragOffset.y)
        } else {
            annotation.points = annotation.points.map { CGPoint(x: $0.x + dragOffset.x, y: $0.y + dragOffset.y) }
        }
        return annotation
    }
    static func selectionHelp(for annotation: EditorAnnotation) -> String {
        if annotation.tool == .text { return "ダブルクリックで文字を修正 / 右側で色・文字サイズ / ドラッグで移動" }
        if [.arrow, .line].contains(annotation.tool) { return "両端の丸をドラッグで調整 / 右側で色・太さ / Delete で削除" }
        return "ドラッグで移動 / 右側でスタイル変更 / Delete で削除 / Esc で選択解除"
    }
    private func cancelMove() {
        draggedEndpointIndex = nil
        dragOrigin = nil
        draggedAnnotation = nil
        dragOffset = .zero
        movePreview = nil
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            draft = nil
            cancelMove()
            commitText(cancel: true)
            document.select(nil)
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            document.removeSelected()
            needsDisplay = true
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let tool = EditorTool.shortcut(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            draft = nil
            cancelMove()
            document.tool = tool
            if tool != .select { document.select(nil) }
            document.status = tool == .select ? "注釈をクリックして選択 / 文字はダブルクリックで修正 / 矢印・線は両端を調整" : "\(tool.title)：画像の上をドラッグ"
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyDown(with: event)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: document.tool == .select ? .arrow : .crosshair) }
}
