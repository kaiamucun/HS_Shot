import XCTest
import AVFoundation
import ScreenCaptureKit
@testable import HSShot

final class CaptureServiceTests: XCTestCase {
    @MainActor
    func testInvalidDelaysAreRejectedBeforeRequestingPermission() async throws {
        let service = CaptureService()
        for delay in [-1, Double.nan, Double.infinity] {
            do {
                _ = try await service.capture(.area, delay: delay)
                XCTFail("Invalid delay must throw")
            } catch CaptureError.invalidDelay {
                // Validation must happen before any permission or native capture call.
            }
        }
    }

    @MainActor
    func testCancelledDelayedCaptureReturnsNoFile() async throws {
        let service = CaptureService()
        let task = Task { try await service.capture(.area, delay: 30) }
        await Task.yield()
        task.cancel()
        let result = try await task.value
        XCTAssertNil(result)
    }

    @MainActor
    func testStoppingAnIdleRecordingReturnsNoFile() async throws {
        let service = RecordingService()
        let result = try await service.stop()
        XCTAssertNil(result)
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isFinishing)
        XCTAssertEqual(service.elapsed, 0)
    }

    func testRecordingWithoutVideoFramesFailsAndRemovesTemporaryFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-empty-\(UUID().uuidString).mp4")
        let writer = try RecordingWriter(outputURL: url, width: 64, height: 64, includeAudio: false) { _ in }
        do {
            _ = try await writer.finish(at: CMTime(seconds: 11, preferredTimescale: 600))
            XCTFail("An empty recording must never become a successful file")
        } catch RecordingError.noVideoFrames {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFinalizationExtendsAStaticFrameUntilTheStopTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-static-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(outputURL: url, width: 64, height: 64, includeAudio: false) { _ in }
        writer.appendVideo(try makeVideoSample(at: 10))
        let result = try await writer.finish(at: CMTime(seconds: 11, preferredTimescale: 600))
        XCTAssertEqual(result, url)
        let asset = AVURLAsset(url: result)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThanOrEqual(duration.seconds, 0.95)
        XCTAssertLessThan(duration.seconds, 1.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testSilentSystemAudioStillProducesAPlayableVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-silent-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(outputURL: url, width: 64, height: 64, includeAudio: true) { _ in }
        writer.appendVideo(try makeVideoSample(at: 10))
        let result = try await writer.finish(at: CMTime(seconds: 11, preferredTimescale: 600))
        let asset = AVURLAsset(url: result)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThanOrEqual(duration.seconds, 0.95)
    }

    func testAudioAndVideoKeepTheirSharedTimestampOffset() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HSShot-audio-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(outputURL: url, width: 64, height: 64, includeAudio: true) { _ in }
        writer.appendAudio(try makeAudioSample(at: 9.5))
        writer.appendVideo(try makeVideoSample(at: 10))
        writer.appendAudio(try makeAudioSample(at: 10.5))
        let result = try await writer.finish(at: CMTime(seconds: 11, preferredTimescale: 600))
        let audioTracks = try await AVURLAsset(url: result).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let segments = try await track.load(.segments)
        // MP4 includes an empty edit from 0 to 0.5. Inspect the media edit rather
        // than the whole audio track, whose range includes that leading silence.
        let mediaSegment = try XCTUnwrap(segments.first(where: { !$0.isEmpty }))
        XCTAssertEqual(mediaSegment.timeMapping.target.start.seconds, 0.5, accuracy: 0.03)
    }

    private func makeAudioSample(at seconds: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 480 * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 480 * 8, flags: 0, blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: 480 * 8), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func makeVideoSample(at seconds: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            memset(baseAddress, 128, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
