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
/// its screen shows now.
struct CaptionStrips {

    /// A capture under way: its session, the strip it is for, and the thumbnail hovered, the current space's or not.
    struct Capture {
        let session: Int
        let key: String
        let place: Int
        let current: Bool
    }

    enum Outcome: Equatable {
        /// From an earlier session: nothing taken.
        case stale
        /// The bar moved, or another thumbnail was hovered, while it ran: nothing taken, and captured again.
        case moved
        /// The screen couldn't be captured: captured again, up to `attemptLimit` times a session.
        case failed
        /// The hovered caption couldn't be erased: captured again once another thumbnail is hovered.
        case missed
        case kept
    }

    static let attemptLimit = CaptionLooks.attemptLimit

    private(set) var kept: [String: CaptionStrip] = [:]
    private(set) var session = 0
    /// What each screen shows behind its bar this session, by `CaptionLooks.screenKey`, and the screens, by display.
    private var backgrounds: [String: String] = [:]
    private var screens: [CGDirectDisplayID: ScreenInfo] = [:]
    /// This session's strips captured, and those captured with the current space's thumbnail hovered.
    private var captured: Set<String> = []
    private var capturedInPill: Set<String> = []
    private var failures: [String: Int] = [:]
    /// The thumbnail hovered when a strip's capture last missed its caption.
    private var missedAt: [String: Int] = [:]

    mutating func beginSession(backgrounds: [String: String], screens: [ScreenInfo]) {
        session += 1
        self.backgrounds = backgrounds
        self.screens = Dictionary(screens.map { ($0.displayID, $0) }) { first, _ in first }
        captured = []
        capturedInPill = []
        failures = [:]
        missedAt = [:]
    }

    /// Where `bar`'s strip is kept; nil for a display not known this session.
    func key(for bar: BarLayout) -> String? {
        screens[bar.displayID]?.uuid.map {
            CaptionStrip.key(display: $0, screen: bar.screen.size, barHeight: bar.frame.height)
        }
    }

    /// What `bar`'s screen shows behind it this session.
    func background(of bar: BarLayout) -> String? {
        backgrounds[CaptionLooks.screenKey(bar.screen)]
    }

    /// `bar`'s screen's pixels to the point; nil for a display not known this session.
    func scale(of bar: BarLayout) -> CGFloat? {
        screens[bar.displayID]?.scale
    }

    /// The strip `bar`'s labels are drawn from: the one kept for its screen and height, unless it was captured over
    /// another background than the screen shows this session.
    func strip(for bar: BarLayout) -> CaptionStrip? {
        guard let key = key(for: bar), let strip = kept[key], let background = background(of: bar),
              strip.background == background
        else { return nil }
        return strip
    }

    /// Whether a strip may yet arrive for `bar` this session: until its captures have failed `attemptLimit` times.
    func mayArrive(for bar: BarLayout) -> Bool {
        guard let key = key(for: bar) else { return false }
        return failures[key, default: 0] < Self.attemptLimit
    }

    /// The capture due of `bar` with the thumbnail at `place` hovered, `current` if it is the current space's: the
    /// session's first, or one to measure the pill its strip lacks. None after a miss until another is hovered.
    func capture(of bar: BarLayout, hovered place: Int, current: Bool) -> Capture? {
        guard let key = key(for: bar), background(of: bar) != nil, mayArrive(for: bar), missedAt[key] != place
        else { return nil }
        let seeksPill = current && strip(for: bar)?.pill == nil && !capturedInPill.contains(key)
        guard !captured.contains(key) || seeksPill else { return nil }
        return Capture(session: session, key: key, place: place, current: current)
    }

    /// Takes in what `capture` brought back, nil when the screen couldn't be captured, unless it belongs to an
    /// earlier session or the bar `moved` while it ran. A strip that measured no pill keeps the one it replaces.
    mutating func finish(_ capture: Capture, _ result: MissionControlCaptionLook.StripCapture?, moved: Bool)
        -> Outcome {
        guard capture.session == session else { return .stale }
        guard !moved else { return .moved }
        switch result {
        case nil:
            failures[capture.key, default: 0] += 1
            return .failed
        case .missed:
            missedAt[capture.key] = capture.place
            return .missed
        case .strip(let strip):
            missedAt[capture.key] = nil
            captured.insert(capture.key)
            if capture.current { capturedInPill.insert(capture.key) }
            kept[capture.key] = strip.keepingPill(of: kept[capture.key])
            return .kept
        }
    }

    /// Takes strips read from disk, for screens and heights this run has captured none for.
    mutating func adopt(_ stored: [String: CaptionStrip]) {
        kept.merge(stored) { current, _ in current }
    }
}

// MARK: - On disk

/// The strips kept in Spaceman's caches folder, one file each, read and written off the main thread.
enum CaptionStripStore {

    private static let log = Logger(subsystem: Constants.AppInfo.bundleId, category: "missionControlLook")
    private static let queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).captionStrips", qos: .utility)
    private static let version = 1

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
            fontSize: strip.text.fontSize, textColor: textColor, pill: pill, background: strip.background)
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
            text: CaptionStrip.TextStyle(fontSize: stored.fontSize, color: textColor), pill: pill,
            background: stored.background)
    }

    private static func components(of color: CGColor, in space: CGColorSpace) -> [CGFloat]? {
        color.converted(to: space, intent: .defaultIntent, options: nil)?.components
    }

    private static func color(_ components: [CGFloat], in space: CGColorSpace) -> CGColor? {
        guard components.count == space.numberOfComponents + 1 else { return nil }
        return CGColor(colorSpace: space, components: components)
    }
}
