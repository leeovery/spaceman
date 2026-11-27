//
//  CaptionStrips.swift
//  Spaceman
//
//  The caption strips kept for the run and on disk, and what each session's captures of them have done.
//

import AppKit

/// The magnifying bars' caption strips, kept for the run and in Spaceman's caches folder so even a run's first hover
/// is labelled at once, and this session's captures of them. Each session captures each strip until two captures
/// agree, so a changed wallpaper is picked up; a strip kept from before draws until then, unless captured over another
/// background than its screen shows now. A capture that measures the captions otherwise than the strip drawn replaces
/// it only once another agrees, and only a strip two captures agree on is written to disk.
struct CaptionStrips {

    /// A capture under way: its session, the strip it is for, the thumbnail hovered, the current space's or not, and
    /// its frame; whether it only seeks the pill of a strip already captured; and how many times the hovered thumbnail
    /// had changed when it started.
    struct Capture {
        let session: Int
        let key: String
        let place: Int
        let current: Bool
        let thumbnail: CGRect
        let seeksPill: Bool
        let hoverChanges: Int
    }

    /// What a capture came to. All but `kept` wait `retryDelay` before the next.
    enum Outcome: Equatable {
        /// From an earlier session: nothing taken.
        case stale
        /// The bar or the thumbnails moved, or another thumbnail was hovered, while it ran: no evidence a capture
        /// can't succeed, so it costs nothing.
        case moved
        /// The screen couldn't be captured. Counts towards `attemptLimit`.
        case failed
        /// The hovered caption couldn't be erased, or text was left beside it. Counts towards `attemptLimit`.
        case missed
        /// It measured the captions otherwise than the strip drawn: held until another capture agrees with it.
        /// Counts towards `heldLimit`.
        case held
        /// Drawn, there being no strip to draw, but not yet agreed on by a second capture.
        case drawn
        /// Drawn, two captures agreeing on it: kept on disk.
        case kept
    }

    static let attemptLimit = CaptionLooks.attemptLimit
    static let heldLimit = 2
    /// How long the hovered thumbnail, the thumbnails' sizes and the bar must stay as they are before a capture:
    /// macOS's captions fade in and out over about 100ms (filmed on macOS 26.7), and one caught fading is measured dim
    /// or left behind, one caught moving off centre.
    static let settle: TimeInterval = 0.15
    static let retryDelay: TimeInterval = 0.25
    /// How long a bar may be hovered with no strip before its labels stop waiting for one and fall back.
    static let hoverWait: TimeInterval = 1.0
    /// How far a hovered thumbnail may have moved by the first reading after the shot, in points.
    static let thumbnailTolerance: CGFloat = 0.5

    /// A bar as its strip is kept: by display, screen size and bar height.
    private struct BarID: Hashable {
        let display: CGDirectDisplayID
        let width: Int
        let height: Int
        let barHeight: Int

        init(_ bar: BarLayout) {
            display = bar.displayID
            width = Int(bar.screen.width.rounded())
            height = Int(bar.screen.height.rounded())
            barHeight = Int(bar.frame.height.rounded())
        }
    }

    /// One strip's hover this session: the thumbnail hovered and since when, how often that changed, when it was
    /// last seen hovered, and how long it has been hovered with no strip to draw.
    private struct Hover {
        var place: Int?
        var since: TimeInterval = 0
        var changes = 0
        var lastSeen: TimeInterval?
        var waited: TimeInterval = 0
    }

    /// What one kind of capture of a strip has spent this session: captures that failed or missed, and those held.
    private struct Budget {
        var spent = 0
        var held = 0

        var isLeft: Bool { spent < CaptionStrips.attemptLimit && held < CaptionStrips.heldLimit }
    }

    private(set) var kept: [String: CaptionStrip] = [:]
    private(set) var session = 0
    /// What each screen shows behind its bar this session, by `CaptionLooks.screenKey`, and the screens, by display.
    private var backgrounds: [String: String] = [:]
    private var screens: [CGDirectDisplayID: ScreenInfo] = [:]
    /// This session's keys by bar, the background behind each key's bar, and the strips drawn: those kept that
    /// were captured over it.
    private var keys: [BarID: String] = [:]
    private var backgroundOf: [String: String] = [:]
    private var drawable: [String: CaptionStrip] = [:]
    /// Captures that disagreed with the strip drawn, each waiting for another to agree.
    private var waiting: [String: CaptionStrip] = [:]
    /// What captures last saw of each strip's caption, and the background they saw it over, kept for the run.
    private var sightings: [String: (seen: CaptionSighting, background: String)] = [:]
    /// This session's strips agreed on, and those captured with the current space's thumbnail hovered.
    private var captured: Set<String> = []
    private var capturedInPill: Set<String> = []
    private var stripBudgets: [String: Budget] = [:]
    private var pillBudgets: [String: Budget] = [:]
    private var retryAt: [String: TimeInterval] = [:]
    private var hovers: [String: Hover] = [:]
    /// Each strip's style and fallback, worked out once until its strip, its sighting or the looks change.
    private var dressing: [String: (style: CaptionStrip.Style, fallback: StripFallback?)] = [:]

    mutating func beginSession(backgrounds: [String: String], screens: [ScreenInfo]) {
        session += 1
        self.backgrounds = backgrounds
        self.screens = Dictionary(screens.map { ($0.displayID, $0) }) { first, _ in first }
        keys = [:]
        backgroundOf = [:]
        drawable = [:]
        waiting = [:]
        captured = []
        capturedInPill = []
        stripBudgets = [:]
        pillBudgets = [:]
        retryAt = [:]
        hovers = [:]
        dressing = [:]
    }

    /// Where `bar`'s strip is kept; nil for a display not known this session. Worked out once a session per bar.
    mutating func key(for bar: BarLayout) -> String? {
        let id = BarID(bar)
        if let key = keys[id] { return key }
        guard let uuid = screens[bar.displayID]?.uuid else { return nil }
        let key = CaptionStrip.key(display: uuid, screen: bar.screen.size, barHeight: bar.frame.height)
        keys[id] = key
        if let background = backgrounds[CaptionLooks.screenKey(bar.screen)] {
            backgroundOf[key] = background
            drawable[key] = kept[key].flatMap { $0.background == background ? $0 : nil }
        }
        return key
    }

    /// What the screen of the bar whose strip is `key` shows behind it this session.
    func background(forKey key: String) -> String? {
        backgroundOf[key]
    }

    /// `bar`'s screen's pixels to the point; nil for a display not known this session.
    func scale(of bar: BarLayout) -> CGFloat? {
        screens[bar.displayID]?.scale
    }

    /// The bar's top a strip's depths are measured from: where the overlay puts it, the screen's top less the
    /// retraction it lifts the labels by, so a bar resting a little short of fully in isn't lifted twice.
    static func depthTop(of bar: BarLayout) -> CGFloat {
        bar.screen.minY - MissionControlLabels.retraction(bar: bar.frame, screen: bar.screen) * bar.frame.height
    }

    /// Since when a capture's conditions have held: the bars still since `stillSince`, and the thumbnails not resized
    /// since `resizedAt`. Nil while the bars aren't still.
    static func steadySince(stillSince: TimeInterval?, resizedAt: TimeInterval?) -> TimeInterval? {
        stillSince.map { max($0, resizedAt ?? $0) }
    }

    /// Whether a hovered thumbnail first at `start` is still there `now`, as read after a capture's shot.
    static func thumbnailStayed(at start: CGRect, now: CGRect?) -> Bool {
        guard let now else { return false }
        let limit = thumbnailTolerance
        return abs(now.minX - start.minX) <= limit && abs(now.minY - start.minY) <= limit
            && abs(now.width - start.width) <= limit && abs(now.height - start.height) <= limit
    }

    /// How `bar`'s labels are drawn, with the thumbnail at `place` hovered, if any, at `time`: from its strip, or
    /// waiting for one, or falling back to plates once none can arrive in time, in the colours a capture saw there or
    /// else `colors`, those measured on its screen.
    mutating func drawing(
        for bar: BarLayout, hovered place: Int?, colors: () -> CaptionLooks.Colors, at time: TimeInterval
    ) -> StripDrawing {
        let scale = scale(of: bar) ?? 2
        guard let key = key(for: bar) else {
            let measured = colors()
            return StripDrawing(key: nil, strip: nil, style: CaptionStrip.style(of: nil, measured: measured),
                                fallback: Self.fallback(seen: nil, measured: measured, scale: scale), awaited: false)
        }
        noteHover(of: key, place: place, at: time)
        let strip = drawable[key]
        let dressed = dressing[key] ?? {
            let measured = colors()
            let seen = sightings[key].flatMap { $0.background == backgroundOf[key] ? $0.seen : nil }
            let made = (style: CaptionStrip.style(of: strip, measured: measured),
                        fallback: Self.fallback(seen: seen, measured: measured, scale: scale))
            dressing[key] = made
            return made
        }()
        return StripDrawing(key: key, strip: strip, style: dressed.style, fallback: dressed.fallback,
                            awaited: strip == nil && mayArrive(key))
    }

    /// The plates a magnifying bar's labels fall back to: in the colours a capture `seen` there, else the colours
    /// `measured` on its screen. None where the bar's colour isn't known.
    static func fallback(seen: CaptionSighting?, measured: CaptionLooks.Colors, scale: CGFloat) -> StripFallback? {
        guard let fill = seen?.barColor ?? measured.bar else { return nil }
        return StripFallback(fill: fill, text: seen?.textColor ?? measured.text ?? CaptionStrip.unmeasuredText,
                             baseline: seen?.baseline, lineOffset: seen?.lineOffset ?? 0, scale: scale)
    }

    /// The capture due of the strip `key`, with the thumbnail at `place`, whose frame is `thumbnail`, hovered,
    /// `current` if it is the current space's, at `time`, all steady since `steadySince`: until two captures agree,
    /// or one to measure the pill the strip lacks. Only once the hover and the rest have settled, `retryDelay` after a
    /// capture that wasn't kept, and while that kind of capture has budget left.
    func capture(
        key: String, hovered place: Int, current: Bool, thumbnail: CGRect, at time: TimeInterval,
        steadySince: TimeInterval
    ) -> Capture? {
        guard backgroundOf[key] != nil, time >= retryAt[key, default: 0], let hover = hovers[key],
              hover.place == place, time - hover.since >= Self.settle, time - steadySince >= Self.settle
        else { return nil }
        let seeksPill = captured.contains(key)
        if seeksPill {
            guard current, drawable[key]?.pill == nil, !capturedInPill.contains(key),
                  pillBudgets[key, default: Budget()].isLeft
            else { return nil }
        } else {
            guard stripBudgets[key, default: Budget()].isLeft else { return nil }
        }
        return Capture(session: session, key: key, place: place, current: current, thumbnail: thumbnail,
                       seeksPill: seeksPill, hoverChanges: hover.changes)
    }

    /// Takes in what `capture` brought back at `time`, nil when the screen couldn't be captured, unless it belongs
    /// to an earlier session, or something `moved` or another thumbnail was hovered while it ran.
    mutating func finish(
        _ capture: Capture, _ result: MissionControlCaptionLook.StripCapture?, moved: Bool, at time: TimeInterval
    ) -> Outcome {
        guard capture.session == session else { return .stale }
        let key = capture.key
        let outcome: Outcome
        if moved || hovers[key]?.changes != capture.hoverChanges {
            outcome = .moved
        } else {
            if let seen = result?.seen, let background = backgroundOf[key] {
                sightings[key] = (seen, background)
                dressing[key] = nil
            }
            switch result {
            case nil: outcome = .failed
            case .missed: outcome = .missed
            case .strip(let strip, _): outcome = take(strip, for: capture)
            }
        }
        spend(outcome, of: capture)
        if outcome != .kept { retryAt[key] = time + Self.retryDelay }
        return outcome
    }

    /// Notes that the looks changed, so each strip's style and fallback are worked out afresh.
    mutating func looksChanged() {
        dressing = [:]
    }

    /// Takes strips read from disk, for screens and heights this run has captured none for.
    mutating func adopt(_ stored: [String: CaptionStrip]) {
        kept.merge(stored) { current, _ in current }
        for (key, background) in backgroundOf where drawable[key] == nil {
            guard let strip = kept[key], strip.background == background else { continue }
            drawable[key] = strip
            dressing[key] = nil
        }
    }

    /// Whether a strip may yet arrive for `key` in time to wait for it: while its screen's background is known, its
    /// captures haven't all failed or missed, and its bar hasn't been hovered for `hoverWait` with none.
    private func mayArrive(_ key: String) -> Bool {
        backgroundOf[key] != nil && stripBudgets[key, default: Budget()].spent < Self.attemptLimit
            && (hovers[key]?.waited ?? 0) < Self.hoverWait
    }

    private mutating func spend(_ outcome: Outcome, of capture: Capture) {
        var budget = (capture.seeksPill ? pillBudgets : stripBudgets)[capture.key, default: Budget()]
        switch outcome {
        case .failed, .missed: budget.spent += 1
        case .held: budget.held += 1
        case .stale, .moved, .drawn, .kept: return
        }
        if capture.seeksPill { pillBudgets[capture.key] = budget } else { stripBudgets[capture.key] = budget }
    }

    private mutating func noteHover(of key: String, place: Int?, at time: TimeInterval) {
        var hover = hovers[key] ?? Hover()
        if hover.place != place {
            hover.place = place
            hover.since = time
            hover.changes += 1
        }
        if place != nil, drawable[key] == nil, let last = hover.lastSeen { hover.waited += time - last }
        hover.lastSeen = place == nil ? nil : time
        hovers[key] = hover
    }

    /// Draws `strip`, unless it measures the captions otherwise than the strip drawn and no capture held before
    /// agrees with it. It is agreed on, and kept, once it agrees with the strip drawn or the one held; with no strip
    /// drawn it is only drawn, until another capture agrees. A strip that measured no pill keeps the one it replaces.
    private mutating func take(_ strip: CaptionStrip, for capture: Capture) -> Outcome {
        let key = capture.key
        let drawn = drawable[key]
        if let drawn, !drawn.agrees(with: strip), waiting[key]?.agrees(with: strip) != true {
            waiting[key] = strip
            return .held
        }
        waiting[key] = nil
        let accepted = strip.keepingPill(of: kept[key])
        kept[key] = accepted
        drawable[key] = accepted
        dressing[key] = nil
        if capture.current { capturedInPill.insert(key) }
        guard drawn != nil else { return .drawn }
        captured.insert(key)
        return .kept
    }
}

/// How a magnifying bar's labels are drawn this frame: its strip's key, its strip if one is drawn, the style its
/// labels take, the plates they fall back to, and whether they wait for a strip rather than fall back.
struct StripDrawing {
    let key: String?
    let strip: CaptionStrip?
    let style: CaptionStrip.Style
    let fallback: StripFallback?
    let awaited: Bool
}

// MARK: - On disk

/// The strips kept in Spaceman's caches folder, one file each, read and written off the main thread.
enum CaptionStripStore {

    private static let folder = "CaptionStrips"
    private static let version = 2

    /// A strip as written: the image as PNG, with what was measured. Colours are components in the image's space.
    private struct Stored: Codable {
        struct Pill: Codable {
            let padding: CGFloat
            let above: CGFloat
            let below: CGFloat
            let color: [CGFloat]
        }

        let version: Int
        let png: Data
        let scale: CGFloat
        let top: CGFloat
        let baseline: CGFloat
        let lineOffset: CGFloat
        let fontSize: CGFloat
        let textColor: [CGFloat]
        let pill: Pill?
        let background: String
    }

    /// Writes `strip` in place of the one kept for `key`.
    static func save(_ strip: CaptionStrip, key: String) {
        CacheFiles.write(key, in: folder) { encode(strip) }
    }

    /// Reads every strip kept, by key, and hands them to `done` on the main thread.
    static func load(_ done: @escaping ([String: CaptionStrip]) -> Void) {
        CacheFiles.readAll(in: folder, decode: decode, done: done)
    }

    static func encode(_ strip: CaptionStrip) -> Data? {
        let space = strip.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let png = CacheFiles.png(of: strip.image),
              let textColor = components(of: strip.text.color, in: space)
        else { return nil }
        let pill = strip.pill.flatMap { pill in
            components(of: pill.color, in: space).map {
                Stored.Pill(padding: pill.padding, above: pill.above, below: pill.below, color: $0)
            }
        }
        let stored = Stored(
            version: version, png: png, scale: strip.scale, top: strip.top, baseline: strip.baseline,
            lineOffset: strip.lineOffset, fontSize: strip.text.fontSize, textColor: textColor, pill: pill,
            background: strip.background)
        return try? PropertyListEncoder().encode(stored)
    }

    static func decode(_ data: Data) -> CaptionStrip? {
        guard let stored = try? PropertyListDecoder().decode(Stored.self, from: data), stored.version == version,
              let image = CacheFiles.image(png: stored.png),
              let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let textColor = color(stored.textColor, in: space)
        else { return nil }
        let pill = stored.pill.flatMap { pill in
            color(pill.color, in: space).map {
                CaptionStrip.PillStyle(padding: pill.padding, above: pill.above, below: pill.below, color: $0)
            }
        }
        return CaptionStrip(
            image: image, scale: stored.scale, top: stored.top, baseline: stored.baseline,
            lineOffset: stored.lineOffset, text: CaptionStrip.TextStyle(fontSize: stored.fontSize, color: textColor),
            pill: pill, background: stored.background)
    }

    private static func components(of color: CGColor, in space: CGColorSpace) -> [CGFloat]? {
        color.converted(to: space, intent: .defaultIntent, options: nil)?.components
    }

    private static func color(_ components: [CGFloat], in space: CGColorSpace) -> CGColor? {
        guard components.count == space.numberOfComponents + 1 else { return nil }
        return CGColor(colorSpace: space, components: components)
    }
}
