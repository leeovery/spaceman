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

    /// Readies the native look for a session: captures start afresh, and looks captured over another
    /// wallpaper or appearance are dropped, so the native captions show until they are captured again.
    func beginLookSession() {
        captureAccess = CGPreflightScreenCaptureAccess()
        restingSignature = nil
        capturedSignature = nil
        captureAttempts = [:]
        spentLooks = []
        let stale = Self.staleScreens(captured: lookBackgrounds, current: Self.currentBackgrounds())
        guard !stale.isEmpty else { return }
        looks = Self.dropping(looks, on: stale)
        looksAnyHeight = Self.dropping(looksAnyHeight, on: stale)
        looksByName = Self.dropping(looksByName, on: stale)
        waitingLooks = Self.dropping(waitingLooks, on: stale)
        for screen in stale { lookBackgrounds[screen] = nil }
        Self.log.log("Dropped looks captured over another background on \(stale.count) screens")
    }

    /// What each screen shows behind its captions, by `screenKey`: its wallpaper and the appearance.
    /// A dynamic or shuffling wallpaper can change the picture without changing these.
    static func currentBackgrounds() -> [String: String] {
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        return Dictionary(NSScreen.screens.map { screen in
            let options = (NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
                .map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
            let image = NSWorkspace.shared.desktopImageURL(for: screen)?.absoluteString ?? "none"
            return (screenKey(ScreenInfo.axFrame(of: screen)), "\(image)|\(options)|\(appearance)|\(opaque)")
        }) { first, _ in first }
    }

    /// The screens whose looks were captured over another background than they show now. A screen
    /// not connected keeps its looks until it is back to compare.
    static func staleScreens(captured: [String: String], current: [String: String]) -> Set<String> {
        Set(captured.compactMap { screen, background in
            current[screen].flatMap { $0 == background ? nil : screen }
        })
    }

    /// `entries`, keyed by `lookKeys` or `nameKey`, without those of `screens`.
    static func dropping<Value>(_ entries: [String: Value], on screens: Set<String>) -> [String: Value] {
        entries.filter { !screens.contains(String($0.key.prefix { $0 != "|" })) }
    }

    /// How long the bars must rest, fully in and unchanged, before they are captured. The Dock reports
    /// where its timed animations end as they start, and they run up to about 0.27s (opening,
    /// thumbnails growing under the pointer), so a bar it reports at rest can still be moving.
    private static let captureSettle: TimeInterval = 0.3
    static let captureAttemptLimit = 4

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

    /// Whether a caption gets a label: in its look, captured or borrowed, or in the fallback style once
    /// no look can arrive for it. Until then its native caption shows, not a label that doesn't match it.
    static func drawsLabel(found: FoundLook?, lookMayArrive: @autoclosure () -> Bool) -> Bool {
        found != nil || !lookMayArrive()
    }

    /// Whether a look may yet be captured for a caption that has none.
    func lookMayArrive(for caption: Caption, on bar: BarLayout, nativeLook: Bool) -> Bool {
        Self.lookMayArrive(
            nativeLook: nativeLook, captureAccess: captureAccess,
            spent: spentLooks.contains(Self.lookKeys(bar: bar, caption: caption).anyHeight))
    }

    /// Not with the native look off or Screen Recording not granted, nor once captures have been spent
    /// on the caption: one found no look for it, or the bars kept moving under them until they gave up.
    static func lookMayArrive(nativeLook: Bool, captureAccess: Bool, spent: Bool) -> Bool {
        nativeLook && captureAccess && !spent
    }

    /// The captions a finished capture leaves spent, by `lookKeys(...).anyHeight`: those it found no look
    /// for, or, for one dropped as the bars moved, all it asked about once it was the last attempt.
    static func spentKeys(
        asked: [(exact: String, anyHeight: String)], found: [String: NativeCaptionLook], dropped: Bool, attempts: Int
    ) -> [String] {
        if dropped { return attempts < captureAttemptLimit ? [] : asked.map(\.anyHeight) }
        return asked.filter { found[$0.exact] == nil }.map(\.anyHeight)
    }

    /// A look by screen, name and bar height, whatever caption it covers.
    private static func nameKey(bar: BarLayout, caption: Caption) -> String {
        "\(screenKey(bar.screen))|\(caption.name)|\(Int(bar.frame.height.rounded()))"
    }

    /// The screen part of every look key: its origin, in AX coordinates.
    static func screenKey(_ screen: CGRect) -> String {
        "\(screen.minX),\(screen.minY)"
    }

    /// A caption's look belongs to its screen, the text it covers and the name over it, and to the
    /// bar's height: hover-expanded thumbnails put the captions over a different part of the bar.
    static func lookKeys(bar: BarLayout, caption: Caption) -> (exact: String, anyHeight: String) {
        let anyHeight = "\(screenKey(bar.screen))|\(caption.covers)|\(caption.name)"
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
        guard captureAccess else { return }
        capturedSignature = signature
        captureAttempts[signature] = attempts + 1
        isCapturing = true
        let motion = motionCount
        let screens = Set(bars.map { Self.screenKey($0.screen) })
        let backgrounds = Self.currentBackgrounds().filter { screens.contains($0.key) }
        let asked = bars.flatMap { bar in
            let rest = bar.atRest()
            return rest.captions.map { Self.lookKeys(bar: rest, caption: $0) }
        }
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
                owner.labels?.finishCapture(
                    found, asked: asked, backgrounds: backgrounds, motion: motion, attempts: attempts + 1)
            }
        }
    }

    /// Keeps a capture's looks, unless the bars moved while it ran. A look that moves a caption waits
    /// for another capture to agree, and the bars are captured again after another rest to see.
    fileprivate func finishCapture(
        _ found: [String: NativeCaptionLook], asked: [(exact: String, anyHeight: String)],
        backgrounds: [String: String], motion: Int, attempts: Int
    ) {
        isCapturing = false
        let dropped = motion != motionCount
        spentLooks.formUnion(Self.spentKeys(asked: asked, found: found, dropped: dropped, attempts: attempts))
        guard !dropped else {
            capturedSignature = nil
            if MissionControlCaptionLook.isDebugging { Self.log.log("Capture dropped: the bars moved while it ran") }
            return
        }
        lookBackgrounds.merge(backgrounds) { $1 }
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
