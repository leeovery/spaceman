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
        guard MissionControlCaptionLook.isEnabled, Self.spacesBarIsInDock, !requestedCaptureAccess else { return }
        requestedCaptureAccess = true
        if !CGPreflightScreenCaptureAccess() {
            Self.log.log("Asking for Screen Recording, to match Mission Control's captions")
            CGRequestScreenCaptureAccess()
        }
    }

    /// How long the bars must rest, fully in and unchanged, before they are captured. The Dock reports
    /// where its timed animations end as they start, and they run up to about 0.27s (opening,
    /// thumbnails growing under the pointer), so a bar it reports at rest can still be moving.
    private static let captureSettle: TimeInterval = 0.3
    private static let captureAttemptLimit = 4

    /// A look for a caption: captured for it exactly, or borrowed from the bar at this height or another.
    typealias FoundLook = (look: NativeCaptionLook, exact: Bool, sameHeight: Bool)

    func look(for caption: Caption, on bar: BarLayout) -> FoundLook? {
        let keys = Self.lookKeys(bar: bar, caption: caption)
        if let look = looks[keys.exact] { return (look, true, true) }
        if let look = looksAnyHeight[keys.anyHeight] { return (look, false, false) }
        // Moved to another thumbnail, as when a desktop comes, goes or is dragged: until a capture
        // of it there, the look it had elsewhere.
        return looksByName[Self.nameKey(bar: bar, caption: caption)].map { ($0, false, true) }
    }

    /// A look by screen, name and bar height, whatever caption it covers.
    private static func nameKey(bar: BarLayout, caption: Caption) -> String {
        "\(bar.screen.minX),\(bar.screen.minY)|\(caption.name)|\(Int(bar.frame.height.rounded()))"
    }

    /// A caption's look belongs to its screen, the text it covers and the name over it, and to the
    /// bar's height: hover-expanded thumbnails put the captions over a different part of the bar.
    static func lookKeys(bar: BarLayout, caption: Caption) -> (exact: String, anyHeight: String) {
        let anyHeight = "\(bar.screen.minX),\(bar.screen.minY)|\(caption.covers)|\(caption.name)"
        return ("\(anyHeight)|\(Int(bar.frame.height.rounded()))", anyHeight)
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
        guard MissionControlCaptionLook.isEnabled else { return }
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
        guard !isCapturing, signature != capturedSignature, attempts < Self.captureAttemptLimit,
              now - restingSince >= Self.captureSettle
        else { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        capturedSignature = signature
        captureAttempts[signature] = attempts + 1
        isCapturing = true
        let motion = motionCount
        let jobs = bars.map { bar in
            let rest = bar.atRest()
            return (displayID: rest.displayID, screen: rest.screen, captions: rest.captions.map { caption in
                CaptionToMatch(
                    key: Self.lookKeys(bar: rest, caption: caption).exact, centre: caption.centre,
                    barTop: rest.frame.minY, barBottom: rest.frame.maxY, maxWidth: caption.maxWidth,
                    covers: caption.covers, name: caption.name)
            })
        }
        let owner = WeakOwner(self)
        Task.detached(priority: .userInitiated) {
            var found: [String: NativeCaptionLook] = [:]
            for job in jobs {
                let looks = await MissionControlCaptionLook.capture(
                    displayID: job.displayID, screen: job.screen, captions: job.captions)
                found.merge(looks ?? [:]) { $1 }
            }
            DispatchQueue.main.async {
                owner.labels?.finishCapture(found, motion: motion)
            }
        }
    }

    /// Keeps a capture's looks, unless the bars moved while it ran. A look that moves a caption waits
    /// for another capture to agree, and the bars are captured again after another rest to see.
    fileprivate func finishCapture(_ found: [String: NativeCaptionLook], motion: Int) {
        isCapturing = false
        guard motion == motionCount else {
            capturedSignature = nil
            if MissionControlCaptionLook.isDebugging { Self.log.log("Capture dropped: the bars moved while it ran") }
            return
        }
        var disputed: [String] = []
        for (key, captured) in found {
            let settled = NativeCaptionLook.settle(captured: captured, held: looks[key], waiting: waitingLooks[key])
            waitingLooks[key] = settled.waiting
            guard let use = settled.use else {
                disputed.append(key)
                continue
            }
            looks[key] = use
            if let separator = key.lastIndex(of: "|") {
                looksAnyHeight[String(key[..<separator])] = use
            }
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 4 {
                looksByName["\(parts[0])|\(parts[parts.count - 2])|\(parts[parts.count - 1])"] = use
            }
        }
        guard !disputed.isEmpty else { return }
        capturedSignature = nil
        restingSince = ProcessInfo.processInfo.systemUptime
        if MissionControlCaptionLook.isDebugging {
            Self.log.log("Capture moved \(disputed.count) captions; waiting for another to agree")
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
