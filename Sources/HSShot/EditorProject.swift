import AppKit
import ImageIO

enum EditorProjectError: LocalizedError {
    case missingData, invalidData, unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .missingData:
            return "編集データが見つからないため、注釈を再編集できません。保存済みの画像はコピー・書き出しできます。"
        case .invalidData:
            return "編集データを読み込めませんでした。保存済みの画像はコピー・書き出しできます。"
        case .unsupportedVersion:
            return "この編集データは新しい形式です。HS Shotを更新してから開いてください。保存済みの画像はコピー・書き出しできます。"
        }
    }
}

/// Private local editing data. Export, copy and drag use the separate flattened PNG only.
/// Keeping the base image in this file makes every history item independent of its predecessors.
struct EditorProject: Codable {
    static let currentSchemaVersion = 1
    static let maximumFileBytes = 384 * 1_024 * 1_024

    var schemaVersion: Int = Self.currentSchemaVersion
    let basePNG: Data
    let sourceTitle: String
    let snapshot: Snapshot

    @MainActor
    init(document: EditorDocument, sourceTitle: String) throws {
        guard let data = NSBitmapImageRep(cgImage: document.base).representation(using: .png, properties: [:]) else {
            throw EditorProjectError.invalidData
        }
        basePNG = data
        self.sourceTitle = sourceTitle
        snapshot = try Snapshot(document.state)
        try validate()
    }

    @MainActor
    func restore(preferences: EditorPreferences? = nil) throws -> EditorDocument {
        let base = try validatedBase()
        let state = try snapshot.editorState(baseWidth: base.width, baseHeight: base.height)
        let image = NSImage(cgImage: base, size: NSSize(width: base.width, height: base.height))
        guard let document = EditorDocument(image: image, preferences: preferences, restoredState: state) else {
            throw EditorProjectError.invalidData
        }
        return document
    }

    func validate() throws {
        let base = try validatedBase()
        _ = try snapshot.editorState(baseWidth: base.width, baseHeight: base.height)
    }

    private func validatedBase() throws -> CGImage {
        guard schemaVersion == Self.currentSchemaVersion else {
            if schemaVersion > Self.currentSchemaVersion { throw EditorProjectError.unsupportedVersion(schemaVersion) }
            throw EditorProjectError.invalidData
        }
        guard sourceTitle.utf8.count <= 16_384, !basePNG.isEmpty, basePNG.count <= 256 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(basePNG as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              Int64(width) * Int64(height) <= 64_000_000,
              let base = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw EditorProjectError.invalidData }
        return base
    }

    struct Snapshot: Codable {
        let annotations: [Annotation]
        let crop: Rectangle?
        let padding: Int
        let background: String

        init(_ state: EditorSnapshot) throws {
            annotations = try state.annotations.map(Annotation.init)
            crop = state.crop.map(Rectangle.init)
            padding = state.padding
            background = state.background.rawValue
        }

        func editorState(baseWidth: Int, baseHeight: Int) throws -> EditorSnapshot {
            guard annotations.count <= 10_000, (0...1_024).contains(padding),
                  let background = EditorBackground(rawValue: background),
                  Set(annotations.map(\.id)).count == annotations.count,
                  annotations.reduce(0, { $0 + $1.points.count }) <= 1_000_000,
                  annotations.reduce(0, { $0 + $1.text.utf8.count }) <= 4_000_000
            else { throw EditorProjectError.invalidData }
            let rect = try crop?.validatedRect()
            let bounds = CGRect(x: 0, y: 0, width: baseWidth, height: baseHeight)
            if let rect {
                guard bounds.contains(rect), rect.width >= 2, rect.height >= 2,
                      rect == rect.integral else { throw EditorProjectError.invalidData }
            }
            let outputWidth = Int(rect?.width ?? CGFloat(baseWidth)) + padding * 2
            let outputHeight = Int(rect?.height ?? CGFloat(baseHeight)) + padding * 2
            guard outputWidth <= 32_768, outputHeight <= 32_768,
                  Int64(outputWidth) * Int64(outputHeight) <= 64_000_000 else { throw EditorProjectError.invalidData }
            return EditorSnapshot(annotations: try annotations.map { try $0.editorAnnotation() },
                                  crop: rect, padding: padding, background: background)
        }
    }

    struct Point: Codable {
        let x: Double
        let y: Double
        init(_ point: CGPoint) { x = point.x; y = point.y }
        func validatedPoint() throws -> CGPoint {
            guard x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else {
                throw EditorProjectError.invalidData
            }
            return CGPoint(x: x, y: y)
        }
    }

    struct Rectangle: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        init(_ rect: CGRect) { x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height }
        func validatedRect() throws -> CGRect {
            guard [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                  width > 0, height > 0 else { throw EditorProjectError.invalidData }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct Color: Codable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        init(_ color: NSColor) throws {
            guard let color = color.usingColorSpace(.sRGB) else { throw EditorProjectError.invalidData }
            let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            guard components.allSatisfy(\.isFinite) else { throw EditorProjectError.invalidData }
            // The renderer's RGB bitmap clips extended-gamut colors too. Store portable sRGB components.
            red = min(1, max(0, color.redComponent)); green = min(1, max(0, color.greenComponent))
            blue = min(1, max(0, color.blueComponent)); alpha = min(1, max(0, color.alphaComponent))
        }
        func validatedColor() throws -> NSColor {
            guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw EditorProjectError.invalidData
            }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    struct Annotation: Codable {
        let id: UUID
        let tool: String
        let points: [Point]
        let color: Color
        let width: Double
        let text: String
        let fontSize: Double
        init(_ annotation: EditorAnnotation) throws {
            id = annotation.id
            tool = annotation.tool.rawValue
            points = annotation.points.map(Point.init)
            color = try Color(annotation.color)
            width = annotation.width
            text = annotation.text
            fontSize = annotation.fontSize
        }
        func editorAnnotation() throws -> EditorAnnotation {
            guard let tool = EditorTool(rawValue: tool), ![.select, .crop].contains(tool),
                  !points.isEmpty, points.count <= 100_000,
                  width.isFinite, (1...20).contains(width),
                  fontSize.isFinite, (12...160).contains(fontSize), text.utf8.count <= 1_000_000 else {
                throw EditorProjectError.invalidData
            }
            if [.arrow, .line, .rectangle, .ellipse, .highlight, .pixelate, .redact].contains(tool), points.count != 2 {
                throw EditorProjectError.invalidData
            }
            return EditorAnnotation(id: id, tool: tool, points: try points.map { try $0.validatedPoint() },
                                    color: try color.validatedColor(), width: width, text: text, fontSize: fontSize)
        }
    }
}
