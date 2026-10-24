// Genuine HS Shot guide capture, macOS 15+; records screen frames only.
// Build:
//   xcrun swiftc -parse-as-library scripts/record-guide.swift -o .build/record-guide \
//     -framework ScreenCaptureKit -framework AVFoundation -framework AppKit -framework CoreGraphics
// Run while DemoBackdrop and the isolated HS Shot demo are open:
//   .build/record-guide --output /absolute/path/take.mp4 [--duration 4] [--display-id 1]
// Press Ctrl-C to finalize. This helper generates no keyboard or mouse events.
// Only the two allowed apps are recorded; app-embedded screenshots must still be safe.

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import AppKit

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line); fflush(stdout)
    }
}

final class FilteredRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    let allowedBundles: Set<String> = ["jp.huntersite.hsshot", "jp.huntersite.hsshot.demo-backdrop"]
    let output: URL
    let durationLimit: Double
    let displayID: CGDirectDisplayID
    let startedAt = Date().timeIntervalSince1970
    let neutralBackground = CGColor(red: 0.94, green: 0.96, blue: 0.98, alpha: 1)
    var firstFrameNotice: Double?
    var stream: SCStream?
    var recording: SCRecordingOutput?
    var finished = false
    var stopRequested = false
    var stopped = false
    var exitCode = 0
    var currentPIDs: Set<pid_t> = []
    var refreshTask: Task<Void, Never>?
    var signalSources: [DispatchSourceSignal] = []

    init(output: URL, durationLimit: Double, displayID: CGDirectDisplayID) {
        self.output = output
        self.durationLimit = durationLimit
        self.displayID = displayID
    }

    func makeFilter(_ content: SCShareableContent) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "HSShotDemoRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Requested display was not found"])
        }
        let apps = content.applications.filter { allowedBundles.contains($0.bundleIdentifier) }
        guard apps.contains(where: { $0.bundleIdentifier == "jp.huntersite.hsshot.demo-backdrop" }) else {
            throw NSError(domain: "HSShotDemoRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Safe DemoBackdrop must be running before capture"])
        }
        currentPIDs = Set(apps.map(\.processID))
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        filter.includeMenuBar = false
        emit(["status": "FILTER", "timestamp_epoch": Date().timeIntervalSince1970,
              "allowed_apps": apps.map { ["bundle": $0.bundleIdentifier, "pid": $0.processID] as [String: Any] },
              "display_id": displayID, "desktop_and_dock": false])
        return filter
    }

    func start() async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "HSShotDemoRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Refusing to overwrite existing recording"])
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        emit(["status": "STARTING", "started_at_epoch": startedAt, "recording_output": output.path,
              "allow_bundles": Array(allowedBundles).sorted(), "native_cursor": true, "native_click_indicators": true])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try makeFilter(content)
        let configuration = SCStreamConfiguration()
        guard let displayMode = CGDisplayCopyDisplayMode(displayID) else {
            throw NSError(domain: "HSShotDemoRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Display mode was not found"])
        }
        configuration.width = displayMode.pixelWidth
        configuration.height = displayMode.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.backgroundColor = neutralBackground
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.ignoreShadowsDisplay = true
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = output
        recordingConfiguration.videoCodecType = .h264
        recordingConfiguration.outputFileType = .mp4
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try captureStream.addRecordingOutput(recordingOutput)
        stream = captureStream
        recording = recordingOutput
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in self?.stopRequested = true }
            source.resume()
            signalSources.append(source)
        }
        try await captureStream.startCapture()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !self.stopped {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if self.stopped { return }
                do {
                    let updated = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    let updatedPIDs = Set(updated.applications.filter { self.allowedBundles.contains($0.bundleIdentifier) }.map(\.processID))
                    if updatedPIDs != self.currentPIDs {
                        let updatedFilter = try self.makeFilter(updated)
                        try await captureStream.updateContentFilter(updatedFilter)
                    }
                } catch {
                    emit(["status": "FILTER_REFRESH_ERROR", "error": String(describing: error)])
                    self.exitCode = 1
                    self.stopRequested = true
                }
            }
        }
    }

    func stop() async {
        if stopped { return }
        stopped = true
        refreshTask?.cancel()
        do { try await stream?.stopCapture() }
        catch {
            emit(["status": "STOP_ERROR", "error": String(describing: error)])
            exitCode = 1; finished = true
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        firstFrameNotice = Date().timeIntervalSince1970
        emit(["status": "RECORDING_READY", "first_frame_notice_epoch": firstFrameNotice!,
              "notice": "Real ScreenCaptureKit frames are being recorded with app allow-list filtering"])
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        emit(["status": "FINISHED", "duration": CMTimeGetSeconds(recordingOutput.recordedDuration), "bytes": recordingOutput.recordedFileSize])
        finished = true
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        emit(["status": "RECORDING_ERROR", "error": String(describing: error)])
        exitCode = 1; finished = true; stopRequested = true
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit(["status": "STREAM_ERROR", "error": String(describing: error)])
        exitCode = 1; finished = true; stopRequested = true
    }
    func writeReceipt() {
        var receipt: [String: Any] = ["output": output.path, "started_at_epoch": startedAt,
            "elapsed_wall_seconds": Date().timeIntervalSince1970 - startedAt,
            "allowed_bundle_ids": Array(allowedBundles).sorted(), "native_cursor": true,
            "native_click_indicators": true, "exit_code": exitCode]
        if let firstFrameNotice { receipt["first_frame_notice_epoch"] = firstFrameNotice }
        if let recording { receipt["recorded_duration"] = CMTimeGetSeconds(recording.recordedDuration); receipt["recorded_bytes"] = recording.recordedFileSize }
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: output.deletingPathExtension().appendingPathExtension("capture.json"))
        }
        emit(receipt)
    }
}

@main struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let outputIndex = args.firstIndex(of: "--output"), args.indices.contains(outputIndex + 1) else {
            fputs("Usage: record-filtered --output /absolute/file.mp4 [--duration seconds] [--display-id ID]\n", stderr); exit(2)
        }
        let output = URL(fileURLWithPath: args[outputIndex + 1]).standardizedFileURL
        var duration: Double = 0
        if let i = args.firstIndex(of: "--duration"), args.indices.contains(i+1) { duration = Double(args[i+1]) ?? 0 }
        var displayID = CGMainDisplayID()
        if let i = args.firstIndex(of: "--display-id"), args.indices.contains(i+1), let value = UInt32(args[i+1]) { displayID = value }
        let recorder = FilteredRecorder(output: output, durationLimit: duration, displayID: displayID)
        do {
            try await recorder.start()
            while !recorder.finished {
                if recorder.stopRequested || (duration > 0 && recorder.firstFrameNotice.map { Date().timeIntervalSince1970 - $0 >= duration } == true) {
                    await recorder.stop()
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            recorder.writeReceipt()
            exit(Int32(recorder.exitCode))
        } catch {
            emit(["status": "FATAL", "error": String(describing: error)])
            exit(1)
        }
    }
}
