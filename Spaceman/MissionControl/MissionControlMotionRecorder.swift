//
//  MissionControlMotionRecorder.swift
//  Spaceman
//
//  Debug only, behind the missionControlMotionRecord default: logs the events Spaceman times its
//  slides from beside where it draws its labels, frame by frame, so the timings in DockMotion can be
//  checked and fitted on this Mac. Everything goes to ~/Library/Caches/<bundle id>/motion.log, stamped
//  with system uptime. For each frame the labels draw it writes an "ours" line: every label shown, as
//  its space's ID at its frame in AX points, where the frame reaching the screen at the stamped time
//  shows it, slides and moves the window server animates included.
//
//  With the missionControlMotionVideo default as well, it also films Mission Control's own captions:
//  it streams the top of the main display with ScreenCaptureKit, without Spaceman's windows, and saves
//  it as video at one pixel a point to motion-frame.mov beside the log, logging each frame's display
//  time as "video frame <index>". The band is missionControlMotionBand points tall, 150 by default:
//  down to the captions of a hover-expanded bar. Every 5 seconds a "video tally" line says how many
//  frames the stream delivered, how many it marked idle (nothing new on screen), how many the encoder
//  couldn't take, and the longest gap between new frames, so a run's analysis can tell how complete the
//  film is. The hardware encodes it, but streaming the screen still loads the window server, so it is
//  for measuring runs only.
//

import AVFoundation
import AppKit
import ScreenCaptureKit

final class MissionControlMotionRecorder: NSObject, SCStreamDelegate {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "missionControlMotionRecord")
    }

    private static var savesVideo: Bool {
        UserDefaults.standard.bool(forKey: "missionControlMotionVideo")
    }

    /// How far down from the top of the display to film, in points.
    private static var band: CGFloat {
        let band = UserDefaults.standard.double(forKey: "missionControlMotionBand")
        return band > 0 ? CGFloat(band) : 150
    }

    /// The folder the log and video go in.
    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Constants.AppInfo.bundleId, isDirectory: true)
    }

    static let shared = MissionControlMotionRecorder()

    private let queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).motionRecorder", qos: .userInitiated)
    /// Formats and writes the log's lines, in the order they are noted, away from the main thread.
    private let logQueue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).motionLog", qos: .utility)
    /// Used only on `logQueue`.
    private var file: FileHandle?
    private var stream: SCStream?
    private var display: SCDisplay?
    private var isStarting = false
    /// The stream's frames' handler, kept for as long as it streams.
    private var output: NativeFrames?

    /// Opens the log and, filming, starts streaming if allowed to record the screen. Main thread.
    func start() {
        guard Self.isEnabled else { return }
        logQueue.async { self.openFile() }
        guard Self.savesVideo, stream == nil, !isStarting, CGPreflightScreenCaptureAccess() else { return }
        isStarting = true
        Task { await startStream() }
    }

    /// Main thread.
    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        if let output { queue.async { output.finish() } }
        output = nil
        note("recorder stopped")
    }

    /// Leaves Spaceman's windows out of the film as they now are. Its label windows are made as
    /// Mission Control first opens, after the stream starts, so call this after each session. Main thread.
    func refreshOwnWindows() {
        guard let stream, let display else { return }
        Task {
            do {
                let own = try await Self.ownWindows()
                try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: own))
            } catch {
                note("recorder: couldn't catch up with Spaceman's windows: \(error.localizedDescription)")
            }
        }
    }

    /// Spaceman's windows, shown or hidden.
    private static func ownWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let pid = getpid()
        return content.windows.filter { $0.owningApplication?.processID == pid }
    }

    /// Writes `text`, stamped with `time` (system uptime). Any thread.
    func note(_ text: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        logQueue.async { self.write(Self.stamped(text, at: time)) }
    }

    /// Writes where `labels` are as the frame reaching the screen at `frameTime` shows them. Any thread.
    func noteDrawn(_ labels: [DrawnLabel], at frameTime: TimeInterval) {
        logQueue.async { self.write(Self.stamped(Self.drawnLine(labels), at: frameTime)) }
    }

    private static func stamped(_ text: String, at time: TimeInterval) -> String {
        String(format: "%.4f ", time) + text
    }

    /// "ours", then each label as "<key>@<x>,<y>,<width>,<height>", in points to a tenth.
    static func drawnLine(_ labels: [DrawnLabel]) -> String {
        labels.reduce(into: "ours") { line, label in
            let frame = label.frame
            line += String(
                format: " %@@%.1f,%.1f,%.1f,%.1f", label.key, frame.minX, frame.minY, frame.width, frame.height)
        }
    }

    private func openFile() {
        guard file == nil, let folder = Self.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("motion.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    private func write(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) { file?.write(data) }
    }

    private func startStream() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) else {
                note("recorder: no main display")
                await MainActor.run { isStarting = false }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: try await Self.ownWindows())
            let stream = try await startStream(filter: filter, display: display)
            await MainActor.run {
                self.stream = stream
                self.display = display
                isStarting = false
            }
        } catch {
            note("recorder failed: \(error.localizedDescription)")
            await MainActor.run { isStarting = false }
        }
    }

    /// Films the top of `display`, as `filter` shows it.
    private func startStream(filter: SCContentFilter, display: SCDisplay) async throws -> SCStream {
        let band = Self.band
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: band)
        config.width = display.width
        config.height = Int(band.rounded())
        // Every frame the display shows.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let video = Self.folder.flatMap {
            FrameVideo(url: $0.appendingPathComponent("motion-frame.mov"), width: config.width, height: config.height)
        }
        let output = NativeFrames(recorder: self, video: video)
        await MainActor.run { self.output = output }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        note("recorder started: display \(display.displayID), \(config.width)x\(config.height)px")
        return stream
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        note("recorder stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if self.stream === stream { self.stream = nil }
        }
    }
}

/// Counts how the stream delivers its frames, summed up every `interval` seconds as a line for the log.
struct FrameTally {

    enum Frame {
        /// A new frame, shown at `shown`, and whether the encoder took it.
        case complete(shown: TimeInterval, written: Bool)
        /// Nothing new on screen.
        case idle
        /// Any other status: blank, suspended, started or stopped.
        case other
    }

    let interval: TimeInterval
    private var since: TimeInterval?
    private var complete = 0
    private var idle = 0
    private var other = 0
    private var unwritten = 0
    private var lastShown: TimeInterval?
    private var longestGap: TimeInterval = 0
    private var longestDelay: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Counts `frame`, arriving at `time` (system uptime). Returns the summary once `interval` has passed
    /// since the first frame it counts, and starts another.
    mutating func count(_ frame: Frame, at time: TimeInterval) -> String? {
        let start = since ?? time
        since = start
        switch frame {
        case let .complete(shown, written):
            complete += 1
            if !written { unwritten += 1 }
            if let lastShown { longestGap = max(longestGap, shown - lastShown) }
            lastShown = shown
            longestDelay = max(longestDelay, time - shown)
        case .idle:
            idle += 1
        case .other:
            other += 1
        }
        return time - start >= interval ? summary(at: time) : nil
    }

    /// The summary of what was counted since the last, or nil with nothing counted; starts another.
    mutating func summary(at time: TimeInterval) -> String? {
        guard let start = since else { return nil }
        let line = String(
            format: "video tally %.1fs: %d complete, %d idle, %d other, %d unwritten, longest gap %.1fms, "
                + "longest delay %.1fms",
            time - start, complete, idle, other, unwritten, longestGap * 1000, longestDelay * 1000)
        // A gap running past the summary counts in the next.
        let carried = lastShown
        self = FrameTally(interval: interval)
        lastShown = carried
        return line
    }
}

/// Writes the stream's frames to the video and tallies how they arrive.
private final class NativeFrames: NSObject, SCStreamOutput {
    private weak var recorder: MissionControlMotionRecorder?
    private let video: FrameVideo?
    /// Used only on the recorder's queue.
    private var frames = 0
    private var tally = FrameTally(interval: 5)
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(recorder: MissionControlMotionRecorder, video: FrameVideo?) {
        self.recorder = recorder
        self.video = video
    }

    /// Notes the tally of the frames since the last. On the recorder's queue.
    func finish() {
        if let line = tally.summary(at: ProcessInfo.processInfo.systemUptime) { recorder?.note(line) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frame: FrameTally.Frame
        if status == .complete, let pixels = sampleBuffer.imageBuffer {
            let shown = (info[.displayTime] as? UInt64).map { Double($0) * Self.timebase } ?? now
            let written = video?.append(pixels, at: shown) ?? false
            if written {
                recorder?.note("video frame \(frames)", at: shown)
                frames += 1
            }
            frame = .complete(shown: shown, written: written)
        } else {
            frame = status == .idle ? .idle : .other
        }
        if let line = tally.count(frame, at: now) { recorder?.note(line, at: now) }
    }
}

/// Saves a stream's frames as H.264 video, each at the time it was shown. Written in one-second
/// fragments, so the file stays readable when Spaceman quits without closing it.
private final class FrameVideo {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false

    init?(url: URL, width: Int, height: Int) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        self.writer = writer
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }

    /// Adds a frame shown at `time` (system uptime); false if the writer couldn't take it.
    func append(_ buffer: CVPixelBuffer, at time: TimeInterval) -> Bool {
        let when = CMTime(seconds: time, preferredTimescale: 1_000_000)
        if !started {
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: when)
            started = true
        }
        guard input.isReadyForMoreMediaData else { return false }
        return adaptor.append(buffer, withPresentationTime: when)
    }
}
