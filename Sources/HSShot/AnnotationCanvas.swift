import AppKit
import Combine

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
    let id = UUID()
    var tool: EditorTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
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
        let fontSize = max(18, width * 5 + 10)
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
            let fontSize = max(18, annotation.width * 5 + 10)
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
    @Published var color: NSColor = NSColor(srgbRed: 0.8, green: 0.96, blue: 0.3, alpha: 1)
    @Published var lineWidth: CGFloat = 5
    @Published var text = "テキスト"
    @Published private(set) var state = EditorSnapshot()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var status = "ツールを選んで画像の上をドラッグ"
    private var undoStates: [EditorSnapshot] = []
    private var redoStates: [EditorSnapshot] = []
    private(set) var preview: CGImage

    init?(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width <= 32_768, cgImage.height <= 32_768,
              Int64(cgImage.width) * Int64(cgImage.height) <= 64_000_000 else { return nil }
        base = cgImage
        preview = cgImage
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
        state = previous
        refresh()
    }
    func redo() {
        guard let next = redoStates.popLast() else { return }
        undoStates.append(state)
        state = next
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
        NSColor(srgbRed: 0.035, green: 0.048, blue: 0.075, alpha: 1).setFill()
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
                context.setFillColor(CGColor(gray: light ? 0.18 : 0.14, alpha: 1))
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
        if var dragged = draggedAnnotation, movePreview != nil {
            dragged.points = dragged.points.map { CGPoint(x: $0.x + dragOffset.x, y: $0.y + dragOffset.y) }
            EditorRenderer.draw(dragged, in: context, base: document.base)
        }
        if let draft, draft.tool != .crop { EditorRenderer.draw(draft, in: context, base: document.base) }
        if var selected = document.selectedAnnotation, document.tool == .select {
            if draggedAnnotation != nil { selected.points = selected.points.map { CGPoint(x: $0.x + dragOffset.x, y: $0.y + dragOffset.y) } }
            context.setStrokeColor(NSColor(srgbRed: 0.8, green: 0.96, blue: 0.3, alpha: 1).cgColor)
            context.setLineWidth(1.5 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale])
            context.stroke(selected.selectionBounds.insetBy(dx: -5 / scale, dy: -5 / scale))
            context.setLineDash(phase: 0, lengths: [])
        }
        if let crop = draft?.tool == .crop ? draft?.rect : document.state.crop {
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            let full = CGRect(x: 0, y: 0, width: document.base.width, height: document.base.height)
            context.addRect(full)
            context.addRect(crop)
            context.drawPath(using: .eoFill)
            context.setStrokeColor(NSColor(srgbRed: 0.8, green: 0.96, blue: 0.3, alpha: 1).cgColor)
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
        commitText()
        window?.makeFirstResponder(self)
        let raw = imagePoint(event, clamp: false)
        guard CGRect(x: 0, y: 0, width: document.base.width, height: document.base.height).contains(raw) else {
            document.select(nil)
            cancelMove()
            needsDisplay = true
            return
        }
        let point = imagePoint(event)
        if document.tool == .select {
            let scale = imageRect.width / CGFloat(document.base.width)
            let selected = document.annotation(at: point, tolerance: 7 / scale)
            document.select(selected?.id)
            draggedAnnotation = selected
            dragOrigin = selected == nil ? nil : point
            dragOffset = .zero
            if let selected {
                movePreview = EditorRenderer.render(base: document.base, annotations: document.state.annotations.filter { $0.id != selected.id }, crop: nil, padding: 0, background: .transparent)
                document.status = "ドラッグで移動 / Delete で削除 / Esc で選択解除"
            } else { movePreview = nil }
            needsDisplay = true
            return
        }
        document.select(nil)
        var annotation = EditorAnnotation(tool: document.tool, points: [point, point], color: document.color, width: document.lineWidth)
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
            document.moveSelected(by: dragOffset)
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
    private func beginText(at point: CGPoint) {
        let rect = imageRect
        let scale = rect.width / CGFloat(document.base.width)
        let origin = CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y, width: min(280, max(100, bounds.width - origin.x - 12)), height: 32))
        field.stringValue = document.text
        field.placeholderString = "テキストを入力"
        field.font = .systemFont(ofSize: max(14, (document.lineWidth * 5 + 10) * scale), weight: .bold)
        field.textColor = document.color
        field.backgroundColor = NSColor(srgbRed: 0.06, green: 0.08, blue: 0.12, alpha: 0.96)
        field.focusRingType = .none
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        textPoint = point
        textEditor = field
        addSubview(field)
        document.status = "テキストを入力：Enter で確定 / Esc で取消"
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    private func commitText(cancel: Bool = false) {
        guard let field = textEditor, let point = textPoint else { return }
        let text = (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        textEditor = nil
        textPoint = nil
        field.delegate = nil
        field.removeFromSuperview()
        if !cancel && !text.isEmpty {
            document.text = text
            document.add(EditorAnnotation(tool: .text, points: [point], color: document.color, width: document.lineWidth, text: text))
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
    private func cancelMove() {
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
            document.status = tool == .select ? "注釈をクリックして選択 / ドラッグで移動 / Delete で削除" : "\(tool.title)：画像の上をドラッグ"
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyDown(with: event)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: document.tool == .select ? .arrow : .crosshair) }
}
