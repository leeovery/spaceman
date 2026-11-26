//
//  MissionControlLabels+Look.swift
//  Spaceman
//
//  Labels drawn to match the captions they cover, from a capture of the bar at rest.
//

import AppKit
import os

extension MissionControlLabels {

    /// Asks, once per launch, for the Screen Recording permission the native look needs.
    func requestCaptureAccessIfNeeded() {
        guard !requestedCaptureAccess, MissionControlLabelStyle.needsScreenRecordingNow() else { return }
        requestedCaptureAccess = true
        Self.log.log("Asking for Screen Recording, to match Mission Control's captions")
        CGRequestScreenCaptureAccess()
    }

    /// Readies the native look for a session: the style is decided afresh, captures start afresh, and
    /// looks captured over another background are dropped, so the native captions show until they are
    /// captured again.
    func beginLookSession() {
        labelStyle = MissionControlLabelStyle.current()
        restingSignature = nil
        capturedSignature = nil
        captureAttempts = [:]
        // A capture from the last session may still be running: it is ignored when it lands.
        isCapturing = false
        captionLooks.beginSession()
        guard labelStyle == .nativeLook else { return }
        let dropped = captionLooks.dropLooks(capturedOver: CaptionLooks.currentBackgrounds())
        if dropped > 0 { Self.log.log("Dropped looks captured over another background on \(dropped) screens") }
    }

    /// How long the bars must rest, fully in and unchanged, before they are captured. The Dock reports
    /// where its timed animations end as they start, and they run up to about 0.27s (opening,
    /// thumbnails growing under the pointer), so a bar it reports at rest can still be moving.
    private static let captureSettle: TimeInterval = 0.3

    typealias FoundLook = CaptionLooks.Found

    /// Whether a look may yet be captured for a caption that has none. If so its native caption shows
    /// until then; if not, its label is drawn in the fallback style so the name still shows.
    func lookMayArrive(for caption: Caption, on bar: BarLayout) -> Bool {
        labelStyle == .nativeLook && captionLooks.lookMayArrive(for: caption, on: bar)
    }

    /// Identifies the bars' layout at rest, so a capture can wait for it to settle.
    private static func signature(of bars: [BarLayout]) -> String {
        bars.map { bar in
            let rest = bar.atRest()
            let names = rest.captions.map { "\($0.covers)=\($0.name)" }.joined(separator: ",")
            return "\(rest.screen)|\(rest.frame.integral)|\(Int((bar.firstButtonX ?? 0).rounded()))|\(names)"
        }.joined(separator: ";")
    }

    /// Notes that the bars moved, or may have: a capture under way may have caught them moving, and the
    /// next waits for them to rest again.
    func noteMotion() {
        motionCount &+= 1
        restingSignature = nil
    }

    /// Once the bars have rested, fully in and unchanged, for a moment, captures them to match the
    /// native captions: each session, and again when they change, as when hovering expands the
    /// thumbnails.
    func captureIfSettled(_ bars: [BarLayout], now: TimeInterval) {
        guard labelStyle == .nativeLook else { return }
        // Captions measured mid-slide sit off their resting places: wait for a measurement at rest.
        guard bars.allSatisfy({ abs($0.frame.minY - $0.screen.minY) < 0.5 }) else {
            noteMotion()
            return
        }
        let signature = Self.signature(of: bars)
        guard signature == restingSignature else {
            noteMotion()
            restingSignature = signature
            restingSince = now
            return
        }
        let attempts = captureAttempts[signature, default: 0]
        guard !isCapturing, signature != capturedSignature, attempts < CaptionLooks.attemptLimit,
              now - restingSince >= Self.captureSettle
        else { return }
        capturedSignature = signature
        captureAttempts[signature] = attempts + 1
        isCapturing = true
        let motion = motionCount
        let capture = captionLooks.capture(of: bars, attempt: attempts + 1)
        let captured = Set(bars.map { CaptionLooks.screenKey($0.screen) })
        let backgrounds = CaptionLooks.currentBackgrounds().filter { captured.contains($0.key) }
        let jobs = bars.map { bar in
            let rest = bar.atRest()
            return (displayID: rest.displayID, screen: rest.screen, captions: rest.captions.map { caption in
                CaptionToMatch(
                    key: CaptionLooks.keys(bar: rest, caption: caption).exact, centre: caption.centre,
                    barTop: rest.frame.minY, barBottom: rest.frame.maxY, maxWidth: caption.maxWidth,
                    covers: caption.covers, name: caption.name)
            })
        }
        let owner = WeakOwner(self)
        Task.detached(priority: .userInitiated) {
            var result = CaptionLooks.Result(backgrounds: backgrounds)
            var reports: [CaptureReport] = []
            for job in jobs {
                guard let captured = await MissionControlCaptionLook.capture(
                    displayID: job.displayID, screen: job.screen, captions: job.captions)
                else {
                    result.failed.insert(CaptionLooks.screenKey(job.screen))
                    continue
                }
                result.found.merge(captured.looks) { $1 }
                if let report = captured.report { reports.append(report) }
            }
            DispatchQueue.main.async {
                owner.labels?.finishCapture(capture, result, motion: motion, reports: reports)
            }
        }
    }

    /// Keeps a capture's looks, unless it is from an earlier session or the bars moved while it ran. The
    /// bars are captured again after another rest when it moved or failed to capture a caption.
    fileprivate func finishCapture(
        _ capture: CaptionLooks.Capture, _ result: CaptionLooks.Result, motion: Int, reports: [CaptureReport]
    ) {
        let moved = motion != motionCount
        let outcome = captionLooks.finish(capture, result, moved: moved)
        for report in reports {
            record(report.line(attempt: capture.attempt, outcome: outcome, moved: moved), at: report.taken)
        }
        guard outcome != .stale else { return }
        isCapturing = false
        guard outcome != .kept else { return }
        capturedSignature = nil
        restingSince = ProcessInfo.processInfo.systemUptime
        if MissionControlCaptionLook.isDebugging {
            let why = outcome == .moved ? "the bars moved while it ran" : "a screen failed or a caption moved"
            let next = capture.attempt < CaptionLooks.attemptLimit ? "capturing again after another rest"
                : "no attempts left for these bars"
            Self.log.log("Capture not all kept: \(why, privacy: .public); \(next, privacy: .public)")
        }
    }
}

/// Lets a capture running off the main thread hand its looks back to the labels, which it only
/// touches on the main thread.
private final class WeakOwner: @unchecked Sendable {
    weak var labels: MissionControlLabels?

    init(_ labels: MissionControlLabels) {
        self.labels = labels
    }
}
