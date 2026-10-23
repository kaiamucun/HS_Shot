import AppKit
import CoreGraphics
import ImageIO

enum CaptureMode: String, CaseIterable {
    case area, window, fullScreen
}

enum CaptureError: LocalizedError {
    case invalidDelay
    case alreadyCapturing
    case permissionDenied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDelay:
            return "撮影までの待ち時間は0〜3,600秒で指定してください。"
        case .alreadyCapturing:
            return "別の撮影が進行中です。選択を完了するか、Escキーでキャンセルしてください。"
        case .permissionDenied:
            return "画面収録の許可が必要です。システム設定 → プライバシーとセキュリティ → 画面収録（画面とシステムオーディオの収録）でHS Shotを許可し、アプリを再起動してください。"
        case .failed(let detail):
            return "スクリーンショットを保存できませんでした。\(detail)"
        }
    }
}

/// Captures native pixels, with an app-owned area selector and macOS's window selector.
/// The caller is responsible for hiding its own windows before starting capture.
@MainActor
final class CaptureService {
    private var isCapturing = false

    func capture(_ mode: CaptureMode, delay: Double = 0) async throws -> URL? {
        guard delay.isFinite, (0...3_600).contains(delay) else { throw CaptureError.invalidDelay }
        guard !isCapturing else { throw CaptureError.alreadyCapturing }
        guard !Task.isCancelled else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        do {
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        } catch is CancellationError {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        if mode == .area {
            do {
                let snapshots = try await AreaSelectionSession.freezeDisplays()
                guard !Task.isCancelled else { return nil }
                let selector = AreaSelectionSession(snapshots: snapshots)
                guard let image = await selector.select(), !Task.isCancelled else { return nil }
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                    throw CaptureError.failed("画像ファイルを作成できませんでした。")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw CaptureError.failed("画像ファイルへの書き込みに失敗しました。")
                }
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                if Task.isCancelled || error is CancellationError { return nil }
                if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
                if let captureError = error as? CaptureError { throw captureError }
                throw CaptureError.failed(error.localizedDescription)
            }
        }
        var arguments = ["-x", "-t", "png"]
        switch mode {
        case .area: break // Handled by the area selection session above.
        case .window: arguments += ["-i", "-w"]
        case .fullScreen: arguments += ["-m"]
        }
        arguments.append(url.path)

        let process = CaptureProcess(arguments: arguments)
        let result: CaptureProcess.Result
        do {
            result = try await withTaskCancellationHandler {
                try await process.run()
            } onCancel: {
                process.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { return nil }
            throw CaptureError.failed(error.localizedDescription)
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if result.status == 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceCreateImageAtIndex(source, 0, nil) != nil {
            return url
        }
        try? FileManager.default.removeItem(at: url)
        if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        // Esc and a zero-area selection exit without an image. Do not create history entries.
        if mode != .fullScreen, result.status == 1,
           detail.isEmpty || detail.localizedCaseInsensitiveContains("cancel") {
            return nil
        }
        throw CaptureError.failed(detail.isEmpty ? "撮影をやり直してください。" : String(detail.prefix(300)))
    }
}

/// Process and cancellation state are protected because a Task cancellation handler may
/// run on a different executor while the native selection interface is active.
private final class CaptureProcess: @unchecked Sendable {
    struct Result { let status: Int32; let error: String }
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    init(arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
    }

    func run() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let errors = Pipe()
            process.standardError = errors
            process.terminationHandler = { process in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Result(status: process.terminationStatus, error: String(data: data, encoding: .utf8) ?? ""))
            }
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                continuation.resume(returning: Result(status: 1, error: ""))
                return
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}
