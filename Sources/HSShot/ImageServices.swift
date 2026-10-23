import AppKit
import Vision

/// Local image processing. Input and output dimensions are measured in pixels, not AppKit points.
enum ImageServices {
    private static let maximumDimension = 32_768
    private static let maximumPixelCount = 50_000_000
    private static let maximumFrameCount = 128
    private static let sampleWidth = 128

    static func recognizeText(in image: NSImage) async throws -> String {
        let pixels = try pixelImage(image)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["ja-JP", "en-US"]
                    request.automaticallyDetectsLanguage = true
                    request.usesLanguageCorrection = true
                    let handler = VNImageRequestHandler(cgImage: pixels, orientation: .up, options: [:])
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: ProcessingError.ocr(error.localizedDescription))
                }
            }
        }
    }

    /// Frames must be taken while scrolling down, with unchanged width and visible shared content.
    /// Ambiguous or missing overlap is an error rather than a potentially corrupt concatenation.
    static func stitch(_ images: [NSImage]) throws -> NSImage {
        guard !images.isEmpty else { throw ProcessingError.noImages }
        guard images.count <= maximumFrameCount else { throw ProcessingError.tooManyFrames }
        let frames = try images.map(pixelImage)
        let width = frames[0].width
        guard frames.allSatisfy({ $0.width == width }) else { throw ProcessingError.differentWidths }

        var pieces: [(image: CGImage, skip: Int)] = [(frames[0], 0)]
        var totalHeight = frames[0].height
        var previous = frames[0]
        var previousSample = try sample(previous)
        for current in frames.dropFirst() {
            let currentSample = try sample(current)
            // Confirm at full resolution so a small changed area cannot disappear during downsampling.
            if previous.height == current.height,
               previousSample.bytes == currentSample.bytes,
               try identicalPixels(previous, current) {
                continue
            }
            let overlap = try findOverlap(previous: previousSample, current: currentSample)
            let addedHeight = current.height - overlap
            let (newHeight, overflow) = totalHeight.addingReportingOverflow(addedHeight)
            guard !overflow else { throw ProcessingError.tooLarge }
            try validateDimensions(width: width, height: newHeight)
            if addedHeight > 0 {
                pieces.append((current, overlap))
                totalHeight = newHeight
            }
            previous = current
            previousSample = currentSample
        }

        if pieces.count == 1 {
            return NSImage(cgImage: pieces[0].image, size: NSSize(width: width, height: totalHeight))
        }
        // Bounds were checked before the output allocation, including integer overflow.
        let colorSpace = frames[0].colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: totalHeight,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProcessingError.allocation
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        var top = 0
        for piece in pieces {
            let height = piece.image.height - piece.skip
            guard let crop = piece.image.cropping(to: CGRect(x: 0, y: piece.skip, width: width, height: height)) else {
                throw ProcessingError.invalidImage
            }
            // CGImage cropping starts at the top; a bitmap drawing context uses bottom-left coordinates.
            context.draw(crop, in: CGRect(x: 0, y: totalHeight - top - height, width: width, height: height))
            top += height
        }
        guard let result = context.makeImage() else { throw ProcessingError.allocation }
        return NSImage(cgImage: result, size: NSSize(width: width, height: totalHeight))
    }

    private struct Sample {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private struct Candidate {
        let overlap: Int
        let score: Double
    }

    private static func findOverlap(previous: Sample, current: Sample) throws -> Int {
        // Equal-size frames with no new rows are only safe when the exact duplicate check passed.
        let maximumOverlap = min(previous.height, current.height) - (previous.height == current.height ? 1 : 0)
        let minimumOverlap = max(8, min(64, maximumOverlap / 8))
        guard maximumOverlap >= minimumOverlap else { throw ProcessingError.noOverlap }
        let tolerance = 3.0 // Average RGB difference on an 8-bit scale.
        var candidates: [Candidate] = []
        for overlap in minimumOverlap...maximumOverlap {
            let score = difference(previous, current, overlap: overlap, rows: min(48, overlap), cutoff: tolerance)
            if score <= tolerance {
                candidates.append(Candidate(overlap: overlap, score: score))
            }
        }
        guard !candidates.isEmpty else { throw ProcessingError.noOverlap }
        candidates.sort { $0.score < $1.score }
        // Large blank/repeating areas can agree at many offsets. Never guess the seam.
        let bestCoarse = candidates[0].score
        let contenders = candidates.filter { $0.score <= bestCoarse + 0.25 }
        guard contenders.count <= 16 else { throw ProcessingError.ambiguousOverlap }
        let refined = contenders.map { candidate in
            Candidate(overlap: candidate.overlap,
                      score: difference(previous, current, overlap: candidate.overlap,
                                        rows: candidate.overlap, cutoff: tolerance))
        }.sorted { $0.score < $1.score }
        guard let best = refined.first, best.score <= tolerance else { throw ProcessingError.noOverlap }
        if refined.dropFirst().contains(where: { $0.score - best.score <= max(0.15, best.score * 0.25) }) {
            throw ProcessingError.ambiguousOverlap
        }
        return best.overlap
    }

    private static func difference(_ previous: Sample, _ current: Sample, overlap: Int, rows: Int, cutoff: Double) -> Double {
        let components = rows * previous.width * 3
        let maximumError = cutoff * Double(components)
        var error = 0
        for row in 0..<rows {
            let y = rows == 1 ? 0 : row * (overlap - 1) / (rows - 1)
            var before = ((previous.height - overlap + y) * previous.width) * 4
            var after = (y * current.width) * 4
            for _ in 0..<previous.width {
                error += abs(Int(previous.bytes[before]) - Int(current.bytes[after]))
                error += abs(Int(previous.bytes[before + 1]) - Int(current.bytes[after + 1]))
                error += abs(Int(previous.bytes[before + 2]) - Int(current.bytes[after + 2]))
                before += 4
                after += 4
            }
            if Double(error) > maximumError { return cutoff + 1 }
        }
        return Double(error) / Double(components)
    }

    private static func sample(_ image: CGImage) throws -> Sample {
        let width = min(sampleWidth, image.width)
        return Sample(width: width, height: image.height, bytes: try raster(image, width: width))
    }

    private static func identicalPixels(_ first: CGImage, _ second: CGImage) throws -> Bool {
        // Stripe comparison bounds temporary memory even for a very tall Retina capture.
        for y in stride(from: 0, to: first.height, by: 128) {
            let height = min(128, first.height - y)
            let rect = CGRect(x: 0, y: y, width: first.width, height: height)
            guard let a = first.cropping(to: rect), let b = second.cropping(to: rect) else {
                throw ProcessingError.invalidImage
            }
            if try raster(a, width: a.width) != raster(b, width: b.width) { return false }
        }
        return true
    }

    private static func raster(_ image: CGImage, width: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ProcessingError.allocation
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        return bytes
    }

    private static func pixelImage(_ image: NSImage) throws -> CGImage {
        // NSImage.size is in points and can be half the true bitmap size on Retina displays.
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.max {
            Double($0.pixelsWide) * Double($0.pixelsHigh) < Double($1.pixelsWide) * Double($1.pixelsHigh)
        }
        let pixels: CGImage
        if let representation = bitmap?.cgImage {
            pixels = representation
        } else {
            guard image.size.width.isFinite, image.size.height.isFinite,
                  image.size.width > 0, image.size.height > 0 else { throw ProcessingError.invalidImage }
            guard image.size.width <= Double(maximumDimension), image.size.height <= Double(maximumDimension) else {
                throw ProcessingError.tooLarge
            }
            try validateDimensions(width: Int(ceil(image.size.width)), height: Int(ceil(image.size.height)))
            guard let representation = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ProcessingError.invalidImage
            }
            pixels = representation
        }
        try validateDimensions(width: pixels.width, height: pixels.height)
        return pixels
    }

    private static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ProcessingError.invalidImage }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, width <= maximumDimension, height <= maximumDimension, pixels <= maximumPixelCount else {
            throw ProcessingError.tooLarge
        }
    }

    private enum ProcessingError: LocalizedError {
        case noImages, invalidImage, differentWidths, noOverlap, ambiguousOverlap, tooLarge, tooManyFrames, allocation
        case ocr(String)

        var errorDescription: String? {
            switch self {
            case .noImages: return "結合する画像を追加してください。"
            case .invalidImage: return "画像のピクセルデータを読み込めませんでした。"
            case .differentWidths: return "画像の幅が一致しません。同じ撮影範囲・倍率で撮影し直してください。"
            case .noOverlap: return "画像の重なりが確認できません。下へ少しずつスクロールし、前の画面を十分に残して撮影してください。"
            case .ambiguousOverlap: return "画像の重なり位置を特定できません。文字や図が重なる位置で、下へ少しずつスクロールして撮影してください。"
            case .tooLarge: return "画像が大きすぎます。縦横32,768ピクセル以内、結合後5,000万ピクセル以内にしてください。"
            case .tooManyFrames: return "一度に結合できる画像は128枚までです。分けて結合してください。"
            case .allocation: return "画像の作成に必要なメモリを確保できませんでした。画像を少なくして試してください。"
            case .ocr(let reason): return "画像の文字を読み取れませんでした。\(reason)"
            }
        }
    }
}
