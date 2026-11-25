//
//  CaptionLooks.swift
//  Spaceman
//
//  The looks captured for Mission Control's captions, and what each session's captures have learned.
//

import AppKit

/// The looks captured for the captions, kept across sessions while the screens show what they were
/// captured over, and the captions this session's captures could find no look for.
struct CaptionLooks {

    /// A look for a caption: captured for it exactly, or borrowed from the bar at this height or another.
    typealias Found = (look: NativeCaptionLook, exact: Bool, sameHeight: Bool)

    /// Where a caption's look is kept. It belongs to its screen, the text it covers and the name over
    /// it, and to the bar's height: hover-expanded thumbnails put the captions over a different part of
    /// the bar. Every key starts with `screen` and a `|`.
    struct Keys {
        let screen: String
        let exact: String
        /// Whatever the bar's height, for a bar that has changed shape since.
        let anyHeight: String
        /// By name alone, whatever caption it covers, for a caption that has moved to another thumbnail.
        let name: String
    }

    /// A capture under way: the session it belongs to, which attempt at the bars it is, and the captions
    /// it asks about.
    struct Capture {
        let session: Int
        let attempt: Int
        let asked: [Keys]
    }

    /// What a capture brought back: looks by `Keys.exact`, the screens it failed to capture, and each
    /// captured screen's background, by `Keys.screen`.
    struct Result {
        var found: [String: NativeCaptionLook] = [:]
        var failed: Set<String> = []
        var backgrounds: [String: String] = [:]
    }

    enum Outcome: Equatable {
        /// From an earlier session: nothing taken.
        case stale
        /// The bars moved while it ran: nothing taken, and the bars are captured again once at rest.
        case moved
        case kept
        /// Kept in part: a screen failed, or a look moved a caption and waits for another capture to agree.
        case retry
    }

    static let attemptLimit = 4
    /// How long, of the bars at rest, a caption waits for its look before its label is drawn in the
    /// fallback style, so names show though no capture ever runs, as when a bar is never reported fully
    /// in. Counted only at rest, so the fallback never switches in over captions on the move.
    static let lookWait: TimeInterval = 1.5

    private var exact: [String: NativeCaptionLook] = [:]
    private var anyHeight: [String: NativeCaptionLook] = [:]
    private var byName: [String: NativeCaptionLook] = [:]
    /// Captures that placed a caption away from its look in use, each waiting for another to agree.
    private var waiting: [String: NativeCaptionLook] = [:]
    /// This session's captions no look can arrive for, by `Keys.anyHeight`.
    private var spent: Set<String> = []
    /// How long the bars have rested this session, and since when they have been resting, if they are.
    private var restTime: TimeInterval = 0
    private var restingAt: TimeInterval?
    /// `restTime` when this session first drew each caption without a look, by `Keys.anyHeight`.
    private var lookless: [String: TimeInterval] = [:]
    /// What each screen showed behind its captions when its looks were captured, by `Keys.screen`.
    private(set) var backgrounds: [String: String] = [:]
    private(set) var session = 0

    static func screenKey(_ screen: CGRect) -> String {
        "\(screen.minX),\(screen.minY)"
    }

    static func keys(bar: BarLayout, caption: Caption) -> Keys {
        let screen = screenKey(bar.screen)
        let height = Int(bar.frame.height.rounded())
        let anyHeight = "\(screen)|\(caption.covers)|\(caption.name)"
        return Keys(
            screen: screen, exact: "\(anyHeight)|\(height)", anyHeight: anyHeight,
            name: "\(screen)|\(caption.name)|\(height)")
    }

    func look(for caption: Caption, on bar: BarLayout) -> Found? {
        let keys = Self.keys(bar: bar, caption: caption)
        if let look = exact[keys.exact] { return (look, true, true) }
        if let look = anyHeight[keys.anyHeight] { return (look, false, false) }
        // Moved to another thumbnail, as when a desktop comes, goes or is dragged: until a capture
        // of it there, the look it had elsewhere.
        return byName[keys.name].map { ($0, false, true) }
    }

    /// Whether a look may yet be captured for a caption that has none: not once a capture has found
    /// none for it or given up, nor once it has waited `lookWait` of the bars at rest.
    mutating func lookMayArrive(for caption: Caption, on bar: BarLayout) -> Bool {
        let key = Self.keys(bar: bar, caption: caption).anyHeight
        guard !spent.contains(key) else { return false }
        let since = lookless[key] ?? restTime
        lookless[key] = since
        return restTime - since < Self.lookWait
    }

    /// Notes, each frame, whether the bars are at rest: fully in, with nothing moving them.
    mutating func noteBars(resting: Bool, at time: TimeInterval) {
        if resting, let since = restingAt { restTime += time - since }
        restingAt = resting ? time : nil
    }

    /// Starts a session: every caption may get its look again.
    mutating func beginSession() {
        session += 1
        spent = []
        restTime = 0
        restingAt = nil
        lookless = [:]
    }

    /// The capture of `bars` at rest as this session's `attempt`.
    func capture(of bars: [BarLayout], attempt: Int) -> Capture {
        Capture(session: session, attempt: attempt, asked: bars.flatMap { bar in
            let rest = bar.atRest()
            return rest.captions.map { Self.keys(bar: rest, caption: $0) }
        })
    }

    /// Takes in what `capture` found, unless it belongs to an earlier session or the bars moved while
    /// it ran. A caption it found no look for is spent; one on a screen it failed to capture is asked
    /// about again, unless this was the last attempt.
    mutating func finish(_ capture: Capture, _ result: Result, moved: Bool) -> Outcome {
        guard capture.session == session else { return .stale }
        let lastAttempt = capture.attempt >= Self.attemptLimit
        guard !moved else {
            if lastAttempt { spent.formUnion(capture.asked.map(\.anyHeight)) }
            return .moved
        }
        var retry = false
        for keys in capture.asked {
            if result.failed.contains(keys.screen) {
                if lastAttempt { spent.insert(keys.anyHeight) } else { retry = true }
            } else if let captured = result.found[keys.exact] {
                if !take(captured, for: keys) { retry = true }
            } else {
                spent.insert(keys.anyHeight)
            }
        }
        backgrounds.merge(result.backgrounds.filter { !result.failed.contains($0.key) }) { $1 }
        return retry ? .retry : .kept
    }

    /// Uses a captured look, unless it moves the caption from the look in use and no earlier capture
    /// agrees with it yet.
    private mutating func take(_ captured: NativeCaptionLook, for keys: Keys) -> Bool {
        let settled = NativeCaptionLook.settle(
            captured: captured, held: exact[keys.exact], waiting: waiting[keys.exact])
        waiting[keys.exact] = settled.waiting
        guard let use = settled.use else { return false }
        exact[keys.exact] = use
        anyHeight[keys.anyHeight] = use
        byName[keys.name] = use
        return true
    }

    /// Drops the looks captured over another background than the screens show now, so their native
    /// captions show until they are captured again. Returns how many screens it dropped.
    mutating func dropLooks(capturedOver current: [String: String]) -> Int {
        let stale = Self.staleScreens(captured: backgrounds, current: current)
        guard !stale.isEmpty else { return 0 }
        exact = Self.dropping(exact, on: stale)
        anyHeight = Self.dropping(anyHeight, on: stale)
        byName = Self.dropping(byName, on: stale)
        waiting = Self.dropping(waiting, on: stale)
        spent = spent.filter { !stale.contains(Self.screen(ofKey: $0)) }
        for screen in stale { backgrounds[screen] = nil }
        return stale.count
    }

    /// The screens whose looks were captured over another background than they show now. A screen
    /// not connected keeps its looks until it is back to compare.
    static func staleScreens(captured: [String: String], current: [String: String]) -> Set<String> {
        Set(captured.compactMap { screen, background in
            current[screen].flatMap { $0 == background ? nil : screen }
        })
    }

    /// `entries`, keyed by `Keys`, without those of `screens`.
    static func dropping<Value>(_ entries: [String: Value], on screens: Set<String>) -> [String: Value] {
        entries.filter { !screens.contains(screen(ofKey: $0.key)) }
    }

    private static func screen(ofKey key: String) -> String {
        String(key.prefix { $0 != "|" })
    }
}

// MARK: - Backgrounds

extension CaptionLooks {

    /// What each screen shows behind its captions, by `Keys.screen`: which display it is, at what size
    /// and scale, the appearance, accent colour and contrast settings, and its wallpaper. A dynamic or
    /// shuffling wallpaper can change the picture without changing these. On the main thread: it takes
    /// a few milliseconds, once a capture.
    static func currentBackgrounds() -> [String: String] {
        let workspace = NSWorkspace.shared
        let appearance = "\(NSApp.effectiveAppearance.name.rawValue)|\(describe(NSColor.controlAccentColor))"
            + "|\(workspace.accessibilityDisplayShouldReduceTransparency)"
            + "|\(workspace.accessibilityDisplayShouldIncreaseContrast)"
        return Dictionary(NSScreen.screens.map { screen in
            let display = MissionControlLabels.displayUUID(of: screen) ?? "unknown"
            let size = screen.frame.size
            let options = (workspace.desktopImageOptions(for: screen) ?? [:])
                .map { "\($0.key.rawValue)=\(describe($0.value))" }.sorted().joined(separator: ",")
            let image = workspace.desktopImageURL(for: screen)?.absoluteString ?? "none"
            return (screenKey(ScreenInfo.axFrame(of: screen)),
                    "\(display)|\(size.width)x\(size.height)@\(screen.backingScaleFactor)|\(appearance)"
                    + "|\(image)|\(options)")
        }) { first, _ in first }
    }

    /// An option's value, the same each time it is read: a colour's description can include its address.
    static func describe(_ value: Any) -> String {
        guard let color = value as? NSColor else { return "\(value)" }
        guard let rgb = color.usingColorSpace(.sRGB) else { return "colour" }
        return String(format: "%.3f %.3f %.3f %.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent,
                      rgb.alphaComponent)
    }
}
