//
//  CaptionStrips.swift
//  Spaceman
//
//  The caption strips kept for the run and on disk, and what each session's captures of them have done.
//

import AppKit
import ImageIO
import os

/// The magnifying bars' caption strips, kept for the run and in Spaceman's caches folder so even a run's first hover
/// is labelled at once, and this session's captures of them. Each session captures each strip once, so a changed
/// wallpaper is picked up; a strip kept from before draws until then, unless captured over another background than
/// its screen shows now. A capture that measures the captions otherwise than the strip drawn replaces it only once
/// another agrees.
struct CaptionStrips {

    /// A capture under way: its session, the strip it is for, the thumbnail hovered, the current space's or not, and
    /// how many times the hovered thumbnail had changed when it started.
    struct Capture {
        let session: Int
        let key: String
        let place: Int
        let current: Bool
        let hoverChanges: Int
    }

    /// What a capture came to. All but `kept` count towards `attemptLimit` and wait `retryDelay` to try again.
    enum Outcome: Equatable {
        /// From an earlier session: nothing taken.
        case stale
        /// The bar moved, or another thumbnail was hovered, while it ran.
        case moved
        /// The screen couldn't be captured.
        case failed
        /// The hovered caption couldn't be erased, or text was left beside it.
        case missed
        /// It measured the captions otherwise than the strip drawn: held until another capture agrees with it.
        case held
        case kept
    }

    static let attemptLimit = CaptionLooks.attemptLimit
    /// How long the hovered thumbnail, and the bar, must stay as they are before a capture: macOS's captions fade in
    /// and out over about 100ms (filmed on macOS 26.7), and one caught fading is measured dim or left behind.
    static let settle: TimeInterval = 0.15
    static let retryDelay: TimeInterval = 0.25
    /// How long a bar may be hovered with no strip before its labels stop waiting for one and fall back.
    static let hoverWait: TimeInterval = 1.0

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
    /// This session's strips captured, and those captured with the current space's thumbnail hovered.
    private var captured: Set<String> = []
    private var capturedInPill: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var retryAt: [String: TimeInterval] = [:]
    private var hovers: [String: Hover] = [:]
    /// Each strip's style and fallback plate, worked out once until its strip or the looks change.
    private var dressing: [String: (style: CaptionStrip.Style, plate: LabelPlate?)] = [:]

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
        attempts = [:]
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

    /// How `bar`'s labels are drawn, with the thumbnail at `place` hovered, if any, at `time`: from its strip, or
    /// waiting for one, or falling back to a plate in `colors`, the colours measured on its screen, once none can
    /// arrive in time.
    mutating func drawing(
        for bar: BarLayout, hovered place: Int?, colors: () -> CaptionLooks.Colors, at time: TimeInterval
    ) -> StripDrawing {
        guard let key = key(for: bar) else {
            let measured = colors()
            return StripDrawing(key: nil, strip: nil, style: CaptionStrip.style(of: nil, measured: measured),
                                plate: Self.plate(from: measured), awaited: false)
        }
        noteHover(of: key, place: place, at: time)
        let strip = drawable[key]
        let dressed = dressing[key] ?? {
            let measured = colors()
            let made = (style: CaptionStrip.style(of: strip, measured: measured), plate: Self.plate(from: measured))
            dressing[key] = made
            return made
        }()
        return StripDrawing(key: key, strip: strip, style: dressed.style, plate: dressed.plate,
                            awaited: strip == nil && mayArrive(key))
    }

    /// The plate a magnifying bar's label falls back to: the bar's colour, with the text's, white where it wasn't
    /// measured. None where the bar's colour isn't known.
    static func plate(from colors: CaptionLooks.Colors) -> LabelPlate? {
        colors.bar.map { LabelPlate(fill: $0, text: colors.text ?? CaptionStrip.unmeasuredText) }
    }

    /// The capture due of the strip `key`, with the thumbnail at `place` hovered, `current` if it is the current
    /// space's, at `time`, the bars still since `stillSince`: the session's first, or one to measure the pill its
    /// strip lacks. Only once the hover and the bars have settled, and `retryDelay` after a capture that came to
    /// nothing.
    func capture(key: String, hovered place: Int, current: Bool, at time: TimeInterval, stillSince: TimeInterval)
        -> Capture? {
        guard backgroundOf[key] != nil, attempts[key, default: 0] < Self.attemptLimit,
              time >= retryAt[key, default: 0], let hover = hovers[key], hover.place == place,
              time - hover.since >= Self.settle, time - stillSince >= Self.settle
        else { return nil }
        let seeksPill = current && drawable[key]?.pill == nil && !capturedInPill.contains(key)
        guard !captured.contains(key) || seeksPill else { return nil }
        return Capture(session: session, key: key, place: place, current: current, hoverChanges: hover.changes)
    }

    /// Takes in what `capture` brought back at `time`, nil when the screen couldn't be captured, unless it belongs
    /// to an earlier session, the bar moved (`barMoved`) or another thumbnail was hovered while it ran.
    mutating func finish(
        _ capture: Capture, _ result: MissionControlCaptionLook.StripCapture?, barMoved: Bool, at time: TimeInterval
    ) -> Outcome {
        guard capture.session == session else { return .stale }
        let outcome: Outcome
        if barMoved || hovers[capture.key]?.changes != capture.hoverChanges {
            outcome = .moved
        } else {
            switch result {
            case nil: outcome = .failed
            case .missed: outcome = .missed
            case .strip(let strip): outcome = take(strip, for: capture)
            }
        }
        if outcome != .kept {
            attempts[capture.key, default: 0] += 1
            retryAt[capture.key] = time + Self.retryDelay
        }
        return outcome
    }

    /// Notes that the looks changed, so each strip's style and plate are worked out afresh.
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
    /// captures haven't all come to nothing and its bar hasn't been hovered for `hoverWait` with none.
    private func mayArrive(_ key: String) -> Bool {
        backgroundOf[key] != nil && attempts[key, default: 0] < Self.attemptLimit
            && (hovers[key]?.waited ?? 0) < Self.hoverWait
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

    /// Draws `strip` from now on, unless it measures the captions otherwise than the strip drawn and no capture
    /// held before agrees with it. A strip that measured no pill keeps the one it replaces.
    private mutating func take(_ strip: CaptionStrip, for capture: Capture) -> Outcome {
        let key = capture.key
        if let held = drawable[key], !held.agrees(with: strip), waiting[key]?.agrees(with: strip) != true {
            waiting[key] = strip
            return .held
        }
        waiting[key] = nil
        let accepted = strip.keepingPill(of: kept[key])
        kept[key] = accepted
        drawable[key] = accepted
        dressing[key] = nil
        captured.insert(key)
        if capture.current { capturedInPill.insert(key) }
        return .kept
    }
}

/// How a magnifying bar's labels are drawn this frame: its strip's key, its strip if one is drawn, the style its
/// labels take, the plate they fall back to, and whether they wait for a strip rather than fall back.
struct StripDrawing {
    let key: String?
    let strip: CaptionStrip?
    let style: CaptionStrip.Style
    let plate: LabelPlate?
    let awaited: Bool
}

// MARK: - On disk

/// The strips kept in Spaceman's caches folder, one file each, read and written off the main thread.
enum CaptionStripStore {

    private static let log = Logger(subsystem: Constants.AppInfo.bundleId, category: "missionControlLook")
    private static let queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).captionStrips", qos: .utility)
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

    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Constants.AppInfo.bundleId, isDirectory: true)
            .appendingPathComponent("CaptionStrips", isDirectory: true)
    }

    /// Writes `strip` in place of the one kept for `key`.
    static func save(_ strip: CaptionStrip, key: String) {
        queue.async {
            guard let folder, let data = encode(strip) else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("\(key).plist"), options: .atomic)
            } catch {
                log.log("Couldn't keep a caption strip: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reads every strip kept, by key, and hands them to `done` on the main thread.
    static func load(_ done: @escaping ([String: CaptionStrip]) -> Void) {
        queue.async {
            var strips: [String: CaptionStrip] = [:]
            let files = folder.flatMap {
                try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
            }
            for file in files ?? [] where file.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: file), let strip = decode(data) else { continue }
                strips[file.deletingPathExtension().lastPathComponent] = strip
            }
            DispatchQueue.main.async { done(strips) }
        }
    }

    static func encode(_ strip: CaptionStrip) -> Data? {
        let png = NSMutableData()
        let space = strip.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil),
              let textColor = components(of: strip.text.color, in: space)
        else { return nil }
        CGImageDestinationAddImage(destination, strip.image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let pill = strip.pill.flatMap { pill in
            components(of: pill.color, in: space).map {
                Stored.Pill(padding: pill.padding, above: pill.above, below: pill.below, color: $0)
            }
        }
        let stored = Stored(
            version: version, png: png as Data, scale: strip.scale, top: strip.top, baseline: strip.baseline,
            lineOffset: strip.lineOffset, fontSize: strip.text.fontSize, textColor: textColor, pill: pill,
            background: strip.background)
        return try? PropertyListEncoder().encode(stored)
    }

    static func decode(_ data: Data) -> CaptionStrip? {
        guard let stored = try? PropertyListDecoder().decode(Stored.self, from: data), stored.version == version,
              let source = CGImageSourceCreateWithData(stored.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
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
