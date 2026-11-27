//
//  MissionControlMotionRecorder.swift
//  Spaceman
//
//  Debug only, behind the missionControlMotionRecord default: logs the events Spaceman times its
//  slides from beside where it draws its labels, frame by frame, so the timings in DockMotion can be
//  checked and fitted on this Mac. Everything goes to ~/Library/Caches/<bundle id>/motion.log, stamped
//  with system uptime. For each frame the labels draw it writes an "ours" line: every label shown, as
//  its space's ID at its frame in AX points, where Spaceman placed it for the frame reaching the screen
//  at the stamped time, the slides and moves it hands the window server worked out for that time. The
//  window server sometimes shows a slide as it was a frame earlier, which only the film below can show.
//  When the labels are hidden it writes "ours" alone.
//
//  With the missionControlMotionVideo default as well, it also films Mission Control's own captions:
//  it streams the top of the main display with ScreenCaptureKit, without Spaceman, and saves
//  it as video at one pixel a point to motion-frame.mov beside the log, logging each frame's display
//  time as "video frame <index>". The band is missionControlMotionBand points tall, 150 by default
//  (down to the captions of a hover-expanded bar), made even and kept within the display. Every 5
//  seconds a "video tally" line says how many frames the stream delivered, how many it marked idle
//  (nothing new on screen), how many the encoder couldn't take, and the longest gap between new frames,
//  so a run's analysis can tell how complete the film is. The hardware encodes it, but streaming the
//  screen still loads the window server, so it is for measuring runs only.
//
//  With the missionControlMotionVideoShown default too, it films the same band a second time, with
//  Spaceman's windows, labels and all, to motion-shown.mov: what the user saw. It logs "shown frame
//  <index>" and "shown tally" lines, their times on the same clock as the first film's, so the two can
//  be matched frame by frame. It streams separately, its frames handled at a lower priority, so when
//  the two can't both keep up it should be this film that loses frames.
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

    /// The films to make: Mission Control's own, then, if asked for, what the user saw.
    private static var films: [Film] {
        UserDefaults.standard.bool(forKey: "missionControlMotionVideoShown") ? [.native, .shown] : [.native]
    }

    /// How far down from the top of the display to film, in points, for a `requested` band and a display
    /// `displayHeight` points tall: 150 unless asked otherwise, to the nearest even number, as H.264 needs,
    /// and no more than the display's height.
    static func band(_ requested: Double, displayHeight: Int) -> Int {
        let even = requested > 0 ? max(Int((requested / 2).rounded()) * 2, 2) : 150
        return min(even, displayHeight / 2 * 2)
    }

    /// The folder the log and videos go in.
    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Constants.AppInfo.bundleId, isDirectory: true)
    }

    static let shared = MissionControlMotionRecorder()

    /// Formats and writes the log's lines, in the order they are noted, away from the main thread.
    private let logQueue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).motionLog", qos: .utility)
    /// Used only on `logQueue`.
    private var file: FileHandle?
    private var filmings: [Filming] = []
    private var isStarting = false

    /// Opens the log and, filming, starts streaming if allowed to record the screen. Main thread.
    func start() {
        guard Self.isEnabled else { return }
        logQueue.async { self.openFile() }
        guard Self.savesVideo, filmings.isEmpty, !isStarting, CGPreflightScreenCaptureAccess() else { return }
        isStarting = true
        let films = Self.films
        Task { await startFilming(films) }
    }

    /// Main thread.
    func stop() {
        filmings.forEach { $0.stop() }
        filmings = []
        if Self.isEnabled { note("recorder stopped") }
    }

    /// Of `applications`, the one running as process `pid`: Spaceman, left out of the films that hide it as an
    /// application, so windows it makes after a film starts, as its label windows are, are left out too.
    static func spaceman<Application>(
        among applications: [Application], pid: pid_t = getpid(), processID: (Application) -> pid_t
    ) -> [Application] {
        applications.filter { processID($0) == pid }
    }

    /// Writes `text`, stamped with `time` (system uptime). Any thread.
    func note(_ text: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        logQueue.async { self.write(Self.stamped(text, at: time)) }
    }

    /// Writes where Spaceman placed `labels` for the frame reaching the screen at `frameTime`. Any thread.
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

    /// Starts each of `films` streaming the main display; one failing leaves the others filming.
    private func startFilming(_ films: [Film]) async {
        var started: [Filming] = []
        do {
            // Every app, not only those with windows on screen: at launch Spaceman shows none, and an app left
            // out of the list can't be excluded.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let mainID = CGMainDisplayID()
            if let display = content.displays.first(where: { $0.displayID == mainID }) {
                let own = Self.spaceman(among: content.applications) { $0.processID }
                note("recorder leaves out \(own.count) app\(own.count == 1 ? "" : "s") from the native film")
                for film in films {
                    do {
                        started.append(try await startFilming(film, display: display, hiding: own))
                    } catch {
                        note(film.prefix + "recorder failed: \(error.localizedDescription)")
                    }
                }
            } else {
                note("recorder: no main display")
            }
        } catch {
            note("recorder failed: \(error.localizedDescription)")
        }
        await MainActor.run { [started] in
            filmings = started
            isStarting = false
        }
    }

    /// Films the top of `display` for `film`, leaving out `own`, Spaceman, if the film hides it.
    private func startFilming(
        _ film: Film, display: SCDisplay, hiding own: [SCRunningApplication]
    ) async throws -> Filming {
        let filter = SCContentFilter(
            display: display, excludingApplications: film.hidesSpaceman ? own : [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        // H.264 takes only even dimensions.
        config.width = display.width / 2 * 2
        config.height = Self.band(
            UserDefaults.standard.double(forKey: "missionControlMotionBand"), displayHeight: display.height)
        config.sourceRect = CGRect(x: 0, y: 0, width: config.width, height: config.height)
        // Every frame the display shows.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let video = Self.folder.flatMap {
            FrameVideo(url: $0.appendingPathComponent(film.file), width: config.width, height: config.height)
        }
        let filming = Filming(film: film, stream: stream, frames: FilmFrames(recorder: self, film: film, video: video))
        try stream.addStreamOutput(filming.frames, type: .screen, sampleHandlerQueue: filming.queue)
        try await stream.startCapture()
        note(film.prefix + "recorder started: display \(display.displayID), \(config.width)x\(config.height)px")
        return filming
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            let prefix = self.filmings.first { $0.stream === stream }?.film.prefix ?? ""
            self.note(prefix + "recorder stopped with error: \(error.localizedDescription)")
            self.filmings.removeAll { $0.stream === stream }
        }
    }
}

/// One of the films the recorder makes.
private struct Film {
    /// The video's file name, beside the log.
    let file: String
    /// What its frame and tally lines are called: "<name> frame", "<name> tally".
    let name: String
    let hidesSpaceman: Bool
    /// The priority its frames are handled at.
    let qos: DispatchQoS

    /// Mission Control's own drawing, without Spaceman's windows.
    static let native = Film(file: "motion-frame.mov", name: "video", hidesSpaceman: true, qos: .userInitiated)
    /// What the user saw, labels and all. Below the native film, so it is the one to drop frames.
    static let shown = Film(file: "motion-shown.mov", name: "shown", hidesSpaceman: false, qos: .utility)

    /// Leads its recorder lines. None for the native film, whose lines came before there were two.
    var prefix: String { hidesSpaceman ? "" : "\(name) " }
}

/// A film being made: its stream, and its frames' handler and their queue, kept for as long as it streams.
private final class Filming {
    let film: Film
    let stream: SCStream
    let frames: FilmFrames
    let queue: DispatchQueue

    init(film: Film, stream: SCStream, frames: FilmFrames) {
        self.film = film
        self.stream = stream
        self.frames = frames
        queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).motionRecorder.\(film.name)", qos: film.qos)
    }

    /// Main thread.
    func stop() {
        stream.stopCapture { _ in }
        queue.async { [frames] in frames.finish() }
    }
}

/// Counts how a stream delivers its frames, summed up every `interval` seconds as a line for the log.
struct FrameTally {

    enum Frame {
        /// A new frame, shown at `shown`, and whether the encoder took it.
        case complete(shown: TimeInterval, written: Bool)
        /// Nothing new on screen.
        case idle
        /// Any other status: blank, suspended, started or stopped.
        case other
    }

    /// Leads the summary, as "<name> tally".
    let name: String
    let interval: TimeInterval
    private var since: TimeInterval?
    private var complete = 0
    private var idle = 0
    private var other = 0
    private var unwritten = 0
    private var lastShown: TimeInterval?
    private var longestGap: TimeInterval = 0
    private var longestDelay: TimeInterval = 0

    init(name: String, interval: TimeInterval) {
        self.name = name
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
            format: "%@ tally %.1fs: %d complete, %d idle, %d other, %d unwritten, longest gap %.1fms, "
                + "longest delay %.1fms",
            name, time - start, complete, idle, other, unwritten, longestGap * 1000, longestDelay * 1000)
        // A gap running past the summary counts in the next.
        let carried = lastShown
        self = FrameTally(name: name, interval: interval)
        lastShown = carried
        return line
    }
}

/// Writes a film's frames to its video and tallies how they arrive.
private final class FilmFrames: NSObject, SCStreamOutput {
    private weak var recorder: MissionControlMotionRecorder?
    private let name: String
    private let video: FrameVideo?
    /// Used only on the film's queue.
    private var frames = 0
    private var tally: FrameTally
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(recorder: MissionControlMotionRecorder, film: Film, video: FrameVideo?) {
        self.recorder = recorder
        name = film.name
        self.video = video
        tally = FrameTally(name: film.name, interval: 5)
    }

    /// Notes the tally of the frames since the last. On the film's queue.
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
                recorder?.note("\(name) frame \(frames)", at: shown)
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
