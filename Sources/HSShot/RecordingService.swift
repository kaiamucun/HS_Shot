import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case busy
    case permissionDenied
    case noDisplay
    case noVideoFrames
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "録画の開始または保存処理が進行中です。完了までお待ちください。"
        case .permissionDenied: return CaptureError.permissionDenied.errorDescription
        case .noDisplay: return "録画できるディスプレイが見つかりませんでした。"
        case .noVideoFrames: return "映像を取得できなかったため、録画ファイルは保存されませんでした。画面収録の許可を確認し、もう一度お試しください。"
        case .failed(let detail): return "録画を完了できませんでした。\(detail)"
        }
    }
}

@MainActor
final class RecordingService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Also exposes failures that arrive asynchronously from ScreenCaptureKit.
    @Published private(set) var lastError: String?

    private var isStarting = false
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var timer: Task<Void, Never>?
    private var terminalError: Error?

    func start(includeAudio: Bool) async throws {
        guard !isStarting, !isRecording, !isFinishing else { throw RecordingError.busy }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        terminalError = nil
        elapsed = 0
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecordingError.permissionDenied
        }

        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch {
            if !CGPreflightScreenCaptureAccess() { throw RecordingError.permissionDenied }
            throw RecordingError.failed(error.localizedDescription)
        }
        try Task.checkCancellation()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw RecordingError.noDisplay
        }
        let ownApplication = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let size = Self.videoDimensions(width: CGDisplayPixelsWide(display.displayID), height: CGDisplayPixelsHigh(display.displayID))
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = includeAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-recording-\(UUID().uuidString).mp4")
        let sessionID = UUID()
        let recording = try RecordingWriter(outputURL: url, width: size.width, height: size.height, includeAudio: includeAudio) { [weak self] error in
            Task { @MainActor [weak self] in await self?.recordingFailed(error, sessionID: sessionID) }
        }
        recording.sessionID = sessionID
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: recording)
        do {
            try captureStream.addStreamOutput(recording, type: .screen, sampleHandlerQueue: recording.queue)
            if includeAudio { try captureStream.addStreamOutput(recording, type: .audio, sampleHandlerQueue: recording.queue) }
            stream = captureStream
            writer = recording
            try await captureStream.startCapture()
            try Task.checkCancellation()
            if let terminalError { throw terminalError }
            isRecording = true
            let started = ProcessInfo.processInfo.systemUptime
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 200_000_000) }
                    catch { break }
                    self?.elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
                }
            }
        } catch {
            try? await captureStream.stopCapture()
            await recording.cancel()
            stream = nil
            writer = nil
            terminalError = nil
            isRecording = false
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() async throws -> URL? {
        guard !isStarting, !isFinishing else { throw RecordingError.busy }
        guard let captureStream = stream, let recording = writer else {
            if let error = terminalError {
                terminalError = nil
                throw error
            }
            return nil
        }
        isRecording = false
        isFinishing = true
        timer?.cancel()
        timer = nil
        defer {
            stream = nil
            writer = nil
            isFinishing = false
            terminalError = nil
        }
        do {
            try await captureStream.stopCapture()
            return try await recording.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        } catch {
            await recording.cancel()
            lastError = error.localizedDescription
            throw error
        }
    }

    private func recordingFailed(_ error: Error, sessionID: UUID) async {
        guard let recording = writer, recording.sessionID == sessionID else { return }
        terminalError = error
        lastError = error.localizedDescription
        // stop() or start() already owns cleanup during its suspension points.
        guard !isStarting, !isFinishing else { return }
        isRecording = false
        isFinishing = true
        timer?.cancel()
        timer = nil
        let captureStream = stream
        try? await captureStream?.stopCapture()
        await recording.cancel()
        stream = nil
        writer = nil
        isFinishing = false
    }

    private static func videoDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        // H.264 remains widely playable; fit Retina/6K displays within a 4K encoder frame.
        let scale = min(1, 4096.0 / Double(max(1, max(width, height))))
        return (max(2, Int(Double(width) * scale) / 2 * 2), max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

/// All AVAssetWriter operations run on one serial queue, including finalization.
/// Both SCK audio and screen timestamps use the host clock. Starting the asset session
/// at the first accepted video timestamp keeps the streams on the same timeline.
final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "jp.huntersite.HSShot.recording", qos: .userInitiated)
    var sessionID = UUID()
    private let outputURL: URL
    private let assetWriter: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let onFailure: (Error) -> Void
    private var firstVideoTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastVideoSample: CMSampleBuffer?
    private var failure: Error?
    private var finishing = false
    private var cancelled = false

    init(outputURL: URL, width: Int, height: Int, includeAudio: Bool, onFailure: @escaping (Error) -> Void) throws {
        self.outputURL = outputURL
        self.onFailure = onFailure
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        assetWriter.shouldOptimizeForNetworkUse = true
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, max(1_000_000, width * height * 4)),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ])
        video.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(video) else { throw RecordingError.failed("映像エンコーダを初期化できませんでした。") }
        assetWriter.add(video)
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(input) else { throw RecordingError.failed("システム音声エンコーダを初期化できませんでした。") }
            assetWriter.add(input)
            audio = input
        } else { audio = nil }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue else { return }
            appendVideo(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(RecordingError.failed(error.localizedDescription)) }
    }

    /// Serializes samples from producers with finalization and cancellation.
    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { self.consumeVideo(sample) }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.async { self.consumeAudio(sample) }
    }

    private func consumeVideo(_ sample: CMSampleBuffer) {
        guard !finishing, !cancelled, failure == nil, CMSampleBufferGetImageBuffer(sample) != nil else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time.isNumeric else { return }
        if firstVideoTime == nil {
            guard assetWriter.startWriting() else { fail(writerError()); return }
            assetWriter.startSession(atSourceTime: time)
            firstVideoTime = time
        }
        if let previous = lastVideoTime, CMTimeCompare(time, previous) <= 0 { return }
        guard video.isReadyForMoreMediaData else { return }
        guard video.append(sample) else { fail(writerError()); return }
        lastVideoTime = time
        lastVideoSample = sample
    }

    private func consumeAudio(_ sample: CMSampleBuffer) {
        guard !finishing, !cancelled, failure == nil, let audio, let start = firstVideoTime else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time.isNumeric, CMTimeCompare(time, start) >= 0, audio.isReadyForMoreMediaData else { return }
        if !audio.append(sample) { fail(writerError()) }
    }

    func finish(at stopTime: CMTime) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finishing, !self.cancelled else {
                    continuation.resume(throwing: RecordingError.busy)
                    return
                }
                self.finishing = true
                if let failure = self.failure {
                    self.removeUnfinishedFile()
                    continuation.resume(throwing: failure)
                } else if self.lastVideoSample == nil {
                    self.removeUnfinishedFile()
                    continuation.resume(throwing: RecordingError.noVideoFrames)
                } else {
                    self.finishWithTerminalFrame(at: stopTime, attempts: 0, continuation: continuation)
                }
            }
        }
    }

    private func finishWithTerminalFrame(at stopTime: CMTime, attempts: Int, continuation: CheckedContinuation<URL, Error>) {
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        guard assetWriter.status == .writing else {
            let error = failure ?? writerError()
            removeUnfinishedFile()
            continuation.resume(throwing: error)
            return
        }
        guard let lastVideoTime, let lastVideoSample else {
            removeUnfinishedFile()
            continuation.resume(throwing: RecordingError.noVideoFrames)
            return
        }
        let frameDuration = CMTime(value: 1, timescale: 30)
        let terminalTime = stopTime.isValid && CMTimeCompare(stopTime, lastVideoTime) > 0 ? stopTime : lastVideoTime
        // A static display may stop delivering new frames. Add one final frame so that
        // a minute of unchanged content produces a minute-long movie.
        if CMTimeCompare(terminalTime, CMTimeAdd(lastVideoTime, frameDuration)) > 0 {
            guard video.isReadyForMoreMediaData else {
                guard attempts < 100 else {
                    removeUnfinishedFile()
                    continuation.resume(throwing: RecordingError.failed("映像の書き込みが応答しませんでした。"))
                    return
                }
                queue.asyncAfter(deadline: .now() + 0.02) {
                    self.finishWithTerminalFrame(at: stopTime, attempts: attempts + 1, continuation: continuation)
                }
                return
            }
            var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: terminalTime, decodeTimeStamp: .invalid)
            var terminalSample: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastVideoSample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &terminalSample)
            guard status == noErr, let terminalSample, video.append(terminalSample) else {
                let error = writerError()
                removeUnfinishedFile()
                continuation.resume(throwing: error)
                return
            }
        }
        assetWriter.endSession(atSourceTime: CMTimeAdd(terminalTime, frameDuration))
        video.markAsFinished()
        audio?.markAsFinished()
        assetWriter.finishWriting {
            self.queue.async {
                self.lastVideoSample = nil
                if self.failure == nil, !self.cancelled, self.assetWriter.status == .completed,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: self.outputURL.path),
                   let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 {
                    continuation.resume(returning: self.outputURL)
                } else {
                    let error = self.failure ?? self.writerError()
                    self.removeUnfinishedFile()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.cancelled = true
                self.removeUnfinishedFile()
                continuation.resume()
            }
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil, !cancelled else { return }
        failure = error
        onFailure(error)
    }

    private func writerError() -> Error {
        RecordingError.failed(assetWriter.error?.localizedDescription ?? "映像データを書き込めませんでした。空き容量を確認してください。")
    }

    private func removeUnfinishedFile() {
        if assetWriter.status == .writing || assetWriter.status == .unknown { assetWriter.cancelWriting() }
        lastVideoSample = nil
        try? FileManager.default.removeItem(at: outputURL)
    }
}
