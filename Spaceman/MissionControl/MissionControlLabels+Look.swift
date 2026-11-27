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
    /// captured again. Caption strips are captured afresh too.
    func beginLookSession() {
        labelStyle = MissionControlLabelStyle.current()
        restingSignature = nil
        capturedSignature = nil
        captureAttempts = [:]
        // A capture from the last session may still be running: it is ignored when it lands.
        isCapturing = false
        isCapturingStrip = false
        shotStrip = nil
        thumbnailsResizedAt = nil
        preparedStyles = [:]
        captionLooks.beginSession()
        let backgrounds = labelStyle == .nativeLook ? CaptionLooks.currentBackgrounds() : [:]
        let screens = ScreenInfo.current()
        magnification.know(screens)
        captionStrips.beginSession(backgrounds: backgrounds, screens: screens)
        guard labelStyle == .nativeLook else { return }
        let dropped = captionLooks.dropLooks(capturedOver: backgrounds)
        if dropped > 0 { Self.log.log("Dropped looks captured over another background on \(dropped) screens") }
    }

    /// How long the bars must rest, fully in and unchanged, before they are captured. The Dock reports
    /// where its timed animations end as they start, and they run up to about 0.27s (opening,
    /// thumbnails growing under the pointer), so a bar it reports at rest can still be moving.
    private static let captureSettle: TimeInterval = 0.3

    typealias FoundLook = CaptionLooks.Found

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
        restingSignature = nil
        if isCapturing, movedAt == nil { movedAt = ProcessInfo.processInfo.systemUptime }
    }

    /// Once the bars have rested, fully in and unchanged, for a moment, captures them to match the
    /// native captions: each session, and again when they change, as when hovering expands the
    /// thumbnails. Magnifying bars are left out: their labels are drawn from their caption strips.
    func captureIfSettled(_ measured: [BarLayout], now: TimeInterval) {
        guard labelStyle == .nativeLook else { return }
        // Captions measured mid-slide sit off their resting places: wait for a measurement at rest.
        guard measured.allSatisfy({ abs($0.frame.minY - $0.screen.minY) < 0.5 }) else {
            noteMotion()
            return
        }
        let bars = Self.barsCapturedByCaption(measured, magnification: magnification)
        let signature = Self.signature(of: bars)
        guard signature == restingSignature else {
            noteMotion()
            restingSignature = signature
            restingSince = now
            return
        }
        let attempts = captureAttempts[signature, default: 0]
        guard !isCapturing, signature != capturedSignature, attempts < CaptionLooks.attemptLimit,
              now - restingSince >= Self.captureSettle, bars.contains(where: { !$0.captions.isEmpty })
        else { return }
        capturedSignature = signature
        captureAttempts[signature] = attempts + 1
        isCapturing = true
        movedAt = nil
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
            var reports: [(screen: String, report: CaptureReport)] = []
            for job in jobs {
                let screen = CaptionLooks.screenKey(job.screen)
                guard let captured = await MissionControlCaptionLook.capture(
                    displayID: job.displayID, screen: job.screen, captions: job.captions)
                else {
                    result.failed.insert(screen)
                    continue
                }
                result.found.merge(captured.looks) { $1 }
                result.taken[screen] = captured.taken
                if let report = captured.report { reports.append((screen, report)) }
            }
            DispatchQueue.main.async {
                owner.labels?.finishCapture(capture, result, reports: reports)
            }
        }
    }

    /// Writes the looks in use on `screens` (`CaptionLooks.Keys.screen`) to disk, each with its background.
    private func keepLooks(on screens: Set<String>) {
        for info in ScreenInfo.current() {
            let screen = CaptionLooks.screenKey(info.frame)
            guard screens.contains(screen), let uuid = info.uuid, let looks = captionLooks.screenLooks(screen)
            else { continue }
            CaptionLookStore.save(looks, file: CaptionLookStore.file(display: uuid, screen: info.frame.size))
        }
    }

    /// Takes the looks read from disk at launch, for the screens as they are, over what they show now.
    func adoptLooks(_ stored: [String: CaptionLooks.ScreenLooks]) {
        let taken = captionLooks.adopt(
            stored, screens: ScreenInfo.current(), current: CaptionLooks.currentBackgrounds())
        record("caption looks kept from before: \(taken) taken")
        guard taken > 0 else { return }
        captionStrips.looksChanged()
        Self.log.log("Took \(taken) caption looks kept from before")
    }

    /// The bars whose captions are captured one by one: all but those known to magnify.
    static func barsCapturedByCaption(_ bars: [BarLayout], magnification: BarMagnification) -> [BarLayout] {
        bars.filter { !magnification.magnifies($0) }
    }

    /// Keeps a capture's looks, unless it is from an earlier session, but for the screens shot after the bars
    /// began to move. The bars are captured again after another rest when a screen was shot moving or failed, or a
    /// caption wasn't matched.
    fileprivate func finishCapture(
        _ capture: CaptionLooks.Capture, _ result: CaptionLooks.Result,
        reports: [(screen: String, report: CaptureReport)]
    ) {
        let moved = CaptionLooks.screensShotMoving(result, movedAt: movedAt)
        let outcome = captionLooks.finish(capture, result, movedOn: moved)
        for (screen, report) in reports {
            record(report.line(attempt: capture.attempt, outcome: outcome, moved: moved.contains(screen)),
                   at: report.taken)
        }
        guard outcome != .stale else { return }
        isCapturing = false
        if outcome == .kept || outcome == .retry {
            captionStrips.looksChanged()
            keepLooks(on: Set(capture.asked.map(\.screen)).subtracting(result.failed).subtracting(moved))
        }
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
final class WeakOwner: @unchecked Sendable {
    weak var labels: MissionControlLabels?

    init(_ labels: MissionControlLabels) {
        self.labels = labels
    }
}
