//
//  MissionControlMotionRecorder.swift
//  Spaceman
//
//  Debug only, behind the missionControlMotionRecord default: records how Mission Control's own
//  captions move, frame by frame, beside the events Spaceman times its slides from and where it
//  draws its labels, so the timings in DockMotion can be checked and fitted on this Mac. It streams
//  the top middle of the main display with ScreenCaptureKit twice: once without Spaceman's windows,
//  for the native captions ("frame" lines), and once with only them, for its labels ("ours" lines).
//  For each new frame it writes how many caption-bright pixels each row of the bar of names holds,
//  and where the captions of a hover-expanded bar start and end across the screen ("frame cols" and
//  "ours cols"). Everything goes to ~/Library/Caches/<bundle id>/motion.log, stamped with system
//  uptime. Streaming the screen twice loads the system enough to change how Spaceman keeps up, so it
//  is for measuring runs only.
//
//  With the missionControlMotionVideo default as well, it skips the pixel counting and instead saves
//  each stream as video, the top 150 points of the whole display at one pixel a point, to
//  motion-frame.mov and motion-ours.mov beside the log, logging each frame's time as "video <kind>
//  <index>". The hardware encodes it, so it loads the system far less.
//

import AVFoundation
import AppKit
import ScreenCaptureKit

final class MissionControlMotionRecorder: NSObject, SCStreamDelegate {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "missionControlMotionRecord")
    }

    fileprivate static var savesVideo: Bool {
        UserDefaults.standard.bool(forKey: "missionControlMotionVideo")
    }

    /// The folder the log and videos go in.
    fileprivate static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Constants.AppInfo.bundleId, isDirectory: true)
    }

    static let shared = MissionControlMotionRecorder()

    /// How far down from the top of the display to capture, in points: down to the captions of a
    /// hover-expanded bar.
    private static let band: CGFloat = 150
    /// Pixel rows counted for the bar of names: its top 60 points.
    fileprivate static let nameRows = 0..<120
    /// Pixel rows holding a hover-expanded bar's captions, 119-143 points down.
    fileprivate static let expandedCaptionRows = 236..<290
    /// The part of the screen's width captured, away from most menu bar items.
    private static let columns: ClosedRange<CGFloat> = 0.3...0.7
    /// A pixel this bright in every channel counts as caption text.
    private static let textBrightness: UInt8 = 190

    private let queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).motionRecorder", qos: .userInitiated)
    private let writeLock = NSLock()
    private var file: FileHandle?
    /// Streams the screen without Spaceman's windows.
    private var stream: SCStream?
    /// Streams only Spaceman's windows, once it has some.
    private var ownStream: SCStream?
    private var display: SCDisplay?
    private var isStarting = false
    /// Each stream's frames' handler, kept for as long as it streams.
    private var outputs: [FrameRows] = []
    private var isStartingOwn = false

    /// Starts streaming, if enabled and allowed to record the screen. Main thread.
    func start() {
        guard Self.isEnabled, stream == nil, !isStarting, CGPreflightScreenCaptureAccess() else { return }
        isStarting = true
        openFile()
        Task { await startStream() }
    }

    /// Main thread.
    func stop() {
        stream?.stopCapture { _ in }
        ownStream?.stopCapture { _ in }
        stream = nil
        ownStream = nil
        outputs = []
        note("recorder stopped")
    }

    /// Catches up with Spaceman's windows as they now are: left out of one stream, the only thing in
    /// the other. Its label windows are made as Mission Control first opens, after the streams start,
    /// so call this after each session. Main thread.
    func refreshOwnWindows() {
        guard let stream, let display, !isStartingOwn else { return }
        let ownStream = ownStream
        if ownStream == nil { isStartingOwn = true }
        Task {
            defer { if ownStream == nil { Task { @MainActor in self.isStartingOwn = false } } }
            do {
                let own = try await Self.ownWindows()
                try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: own))
                guard !own.isEmpty else { return }
                let showingOwn = SCContentFilter(display: display, including: own)
                if let ownStream {
                    try await ownStream.updateContentFilter(showingOwn)
                } else {
                    let started = try await startStream(filter: showingOwn, display: display, kind: "ours")
                    await MainActor.run { self.ownStream = started }
                }
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
        write(String(format: "%.4f ", time) + text)
    }

    private func openFile() {
        guard file == nil, let folder = Self.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("motion.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    private func write(_ line: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
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
            let stream = try await startStream(filter: filter, display: display, kind: "frame")
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

    /// Streams the middle of the top of `display`, as `filter` shows it, writing its frames as `kind`.
    private func startStream(filter: SCContentFilter, display: SCDisplay, kind: String) async throws -> SCStream {
        let video = Self.savesVideo
        let scale = video ? 1 : CGFloat(filter.pointPixelScale)
        let width = CGFloat(display.width)
        let config = SCStreamConfiguration()
        config.sourceRect = video
            ? CGRect(x: 0, y: 0, width: width, height: Self.band)
            : CGRect(
                x: (width * Self.columns.lowerBound).rounded(), y: 0,
                width: (width * (Self.columns.upperBound - Self.columns.lowerBound)).rounded(), height: Self.band)
        config.width = Int(config.sourceRect.width * scale)
        config.height = Int(Self.band * scale)
        // Every frame the display shows.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 6
        config.pixelFormat = video ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let saver = video ? Self.folder.flatMap {
            FrameVideo(url: $0.appendingPathComponent("motion-\(kind).mov"), width: config.width, height: config.height)
        } : nil
        let output = FrameRows(kind: kind, recorder: self, video: saver)
        await MainActor.run { outputs.append(output) }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        note("recorder started: display \(display.displayID), \(config.width)x\(config.height)px at scale \(scale)")
        return stream
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        note("recorder stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if self.stream === stream { self.stream = nil }
            if self.ownStream === stream { self.ownStream = nil }
        }
    }

    /// For each pixel row of the bar of names, how many pixels are caption-bright, up to 255; and the
    /// runs of columns with caption-bright pixels among a hover-expanded bar's captions, gaps of up
    /// to 16 pixels joined, as "start-end" pixel columns.
    fileprivate static func textRows(_ buffer: CVPixelBuffer) -> (rows: [UInt8], columns: String) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return ([], "") }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var bright = [Bool](repeating: false, count: width)
        for row in expandedCaptionRows where row < height {
            let start = pixels + row * stride
            for column in 0..<width where !bright[column] {
                let pixel = start + column * 4
                if pixel[0] > textBrightness, pixel[1] > textBrightness, pixel[2] > textBrightness {
                    bright[column] = true
                }
            }
        }
        var runs: [String] = []
        var runStart: Int?
        var lastBright = -100
        for column in 0..<width where bright[column] {
            if column - lastBright > 16 {
                if let runStart { runs.append("\(runStart)-\(lastBright)") }
                runStart = column
            }
            lastBright = column
        }
        if let runStart { runs.append("\(runStart)-\(lastBright)") }
        let rows = nameRows.filter { $0 < height }.map { row in
            var count = 0
            let start = pixels + row * stride
            for column in 0..<width {
                let pixel = start + column * 4
                if pixel[0] > textBrightness, pixel[1] > textBrightness, pixel[2] > textBrightness {
                    count += 1
                    if count == 255 { break }
                }
            }
            return UInt8(count)
        }
        return (rows, runs.joined(separator: " "))
    }
}

/// Writes a stream's frames: for each new frame, its caption-bright pixels per row.
private final class FrameRows: NSObject, SCStreamOutput {
    private let kind: String
    private weak var recorder: MissionControlMotionRecorder?
    /// Used only on the recorder's queue.
    private var lastRows: [UInt8] = []
    private var lastColumns = ""
    private let video: FrameVideo?
    private var frames = 0
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(kind: String, recorder: MissionControlMotionRecorder, video: FrameVideo?) {
        self.kind = kind
        self.recorder = recorder
        self.video = video
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete,
              let pixels = sampleBuffer.imageBuffer
        else { return }
        let shown = (info[.displayTime] as? UInt64).map { Double($0) * Self.timebase }
            ?? ProcessInfo.processInfo.systemUptime
        if let video {
            if video.append(pixels, at: shown) {
                recorder?.note("video \(kind) \(frames)", at: shown)
                frames += 1
            }
            return
        }
        let (rows, columns) = MissionControlMotionRecorder.textRows(pixels)
        if rows != lastRows {
            lastRows = rows
            recorder?.note(kind + " " + rows.map(String.init).joined(separator: ","), at: shown)
        }
        if columns != lastColumns {
            lastColumns = columns
            recorder?.note(kind + " cols " + columns, at: shown)
        }
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
