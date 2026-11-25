//
//  MissionControlCaptionWatcher.swift
//  Spaceman
//
//  Watches Mission Control's own captions while a thumbnail is dragged, so the labels over them can
//  move when they do. The Dock moves a thumbnail aside by where it draws the dragged one, which no
//  API reports, and the pointer predicts that only to within a few points: a slow drag shows the
//  difference. With Screen Recording permission, this streams the strip of the Spaces Bar that the
//  captions sit in, leaving out Spaceman's own windows, and reports where each caption is in every
//  frame the display shows.
//

import AppKit
import ScreenCaptureKit

/// Where Mission Control's captions are across a strip of a screen, frame by frame.
final class MissionControlCaptionWatcher: NSObject, SCStreamDelegate {

    /// A frame: the middles of the captions in it, in Accessibility's x, left to right, and when it
    /// was shown (system uptime).
    typealias Frame = (middles: [CGFloat], shown: TimeInterval)

    /// Called on the main thread with what happened to the stream, for the debug recording.
    var onNote: ((String) -> Void)?
    /// Called on the main thread as each frame showing a change arrives.
    var onChange: (() -> Void)?

    /// The newest frame, as it arrives on the stream's queue.
    private let newestLock = NSCondition()
    private var newest: Frame?

    /// Whether frames are coming.
    var isLive: Bool {
        newestLock.lock()
        defer { newestLock.unlock() }
        return newest != nil
    }

    /// The newest frame if shown after `last`, having waited up to `wait` for one shown at `expected` or
    /// later: frames arrive just after they are shown, as the next display frame is being drawn.
    func frame(after last: TimeInterval, expecting expected: TimeInterval, waitingUpTo wait: TimeInterval) -> Frame? {
        newestLock.lock()
        defer { newestLock.unlock() }
        let deadline = Date(timeIntervalSinceNow: wait)
        while newest.map({ $0.shown < expected }) ?? true, newestLock.wait(until: deadline) {}
        guard let newest, newest.shown > last else { return nil }
        return newest
    }

    fileprivate func deliver(_ frame: Frame?) {
        newestLock.lock()
        newest = frame
        newestLock.broadcast()
        newestLock.unlock()
    }

    private var stream: SCStream?
    private var output: Output?
    private var isStarting = false
    /// Counts starts and stops, so a start that finishes after a stop is undone.
    private var generation = 0
    private let queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).captionWatcher", qos: .userInteractive)

    /// Starts streaming `band`, a strip of `screen` in Accessibility's coordinates, from the display
    /// `displayID`. Main thread.
    func start(displayID: CGDirectDisplayID, screen: CGRect, band: CGRect) {
        guard stream == nil, !isStarting, CGPreflightScreenCaptureAccess() else { return }
        isStarting = true
        generation += 1
        let attempt = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    await MainActor.run {
                        guard attempt == self.generation else { return }
                        self.isStarting = false
                        self.onNote?("caption watcher: no display \(displayID)")
                    }
                    return
                }
                let pid = getpid()
                let own = content.windows.filter { $0.owningApplication?.processID == pid }
                let filter = SCContentFilter(display: display, excludingWindows: own)
                // In the display's own points, from its top-left corner, at its full resolution.
                let scale = CGFloat(filter.pointPixelScale)
                let config = SCStreamConfiguration()
                config.sourceRect = band.offsetBy(dx: -screen.minX, dy: -screen.minY).integral
                config.width = Int(config.sourceRect.width * scale)
                config.height = Int(config.sourceRect.height * scale)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
                config.queueDepth = 4
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                let output = Output(originX: screen.minX + config.sourceRect.minX, scale: scale, watcher: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                await MainActor.run {
                    guard attempt == self.generation else {
                        stream.stopCapture { _ in }
                        return
                    }
                    self.stream = stream
                    self.output = output
                    self.isStarting = false
                    self.onNote?("caption watcher started, \(config.width)x\(config.height)px")
                }
            } catch {
                await MainActor.run {
                    guard attempt == self.generation else { return }
                    self.isStarting = false
                    self.onNote?("caption watcher failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Main thread.
    func stop() {
        generation += 1
        isStarting = false
        deliver(nil)
        stream?.stopCapture { _ in }
        stream = nil
        output = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.stream = nil
            self.output = nil
            self.deliver(nil)
            self.onNote?("caption watcher stopped: \(error.localizedDescription)")
        }
    }

    /// A pixel this bright in every channel counts as caption text.
    private static let textBrightness: UInt8 = 190
    /// Text this close across, in points, is one caption.
    private static let wordGap: CGFloat = 12
    /// Text narrower than this, in points, is not a caption.
    private static let minimumWidth: CGFloat = 4

    /// The middles of the runs of caption-bright columns in `buffer`, in points from its left edge, at
    /// `scale` pixels a point.
    fileprivate static func captionMiddles(_ buffer: CVPixelBuffer, scale: CGFloat) -> [CGFloat] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var bright = [Bool](repeating: false, count: width)
        for row in 0..<height {
            let start = pixels + row * stride
            for column in 0..<width where !bright[column] {
                let pixel = start + column * 4
                if pixel[0] > textBrightness, pixel[1] > textBrightness, pixel[2] > textBrightness {
                    bright[column] = true
                }
            }
        }
        let gap = Int((wordGap * scale).rounded())
        let narrowest = Int((minimumWidth * scale).rounded())
        var middles: [CGFloat] = []
        var runStart: Int?
        var last = -gap - 1
        func close() {
            if let runStart, last - runStart + 1 >= narrowest {
                middles.append(CGFloat(runStart + last + 1) / 2 / scale)
            }
        }
        for column in 0..<width where bright[column] {
            if column - last > gap {
                close()
                runStart = column
            }
            last = column
        }
        close()
        return middles
    }
}

/// Hands each new frame's caption middles to the watcher.
private final class Output: NSObject, SCStreamOutput {
    /// Accessibility's x of the frame's left edge, and its pixels a point.
    private let originX: CGFloat
    private let scale: CGFloat
    private weak var watcher: MissionControlCaptionWatcher?
    /// The last frame's caption middles, for frames that show no change. Used only on the stream's queue.
    private var lastMiddles: [CGFloat]?
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(originX: CGFloat, scale: CGFloat, watcher: MissionControlCaptionWatcher) {
        self.originX = originX
        self.scale = scale
        self.watcher = watcher
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        else { return }
        let shown = (info[.displayTime] as? UInt64).map { Double($0) * Self.timebase }
            ?? ProcessInfo.processInfo.systemUptime
        switch status {
        case .complete:
            guard let pixels = sampleBuffer.imageBuffer else { return }
            let middles = MissionControlCaptionWatcher.captionMiddles(pixels, scale: scale).map { originX + $0 }
            let changed = middles != lastMiddles
            lastMiddles = middles
            watcher?.deliver((middles, shown))
            if changed { DispatchQueue.main.async { [weak watcher] in watcher?.onChange?() } }
        case .idle:
            // Nothing changed on screen.
            if let lastMiddles { watcher?.deliver((lastMiddles, shown)) }
        default:
            break
        }
    }
}
