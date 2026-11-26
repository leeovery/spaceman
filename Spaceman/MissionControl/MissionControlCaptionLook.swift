//
//  MissionControlCaptionLook.swift
//  Spaceman
//
//  Makes the name labels look like Mission Control's own "Desktop N" captions.
//
//  With Screen Recording permission, Spaceman captures each Spaces Bar once it is at rest, leaving
//  out its own labels. Behind each caption it finds either the bar or, for the current space, a
//  pill, and it measures the caption's text. Each label is then drawn as that patch of bar with the
//  text erased, or as a matching pill, with the name in the caption's own size and colour. The
//  labels move with the bar, so the patch each one carries stays over the part of the bar it came
//  from as the bar slides.
//

import AppKit
import CoreText
import ImageIO
import ScreenCaptureKit
import os

/// How to draw a label to match a native caption, as a plain caption on the bar and as the
/// current space's caption in a pill: the current space can change while Mission Control is open.
struct NativeCaptionLook {
    struct Variant {
        /// Where the image goes, in points relative to the caption's centre as the Dock reported it, y down.
        let frame: CGRect
        /// The image's top below the bar's top, in points: where the native caption actually was. The
        /// Dock's caption positions can be a few points out while the bar settles; this is not.
        let top: CGFloat
        let image: CGImage
    }

    let plain: Variant?
    let current: Variant?
    /// Whether the caption was the current space's when captured.
    let wasCurrent: Bool
    /// What was measured, for the log.
    let summary: String

    func variant(current isCurrent: Bool) -> Variant? {
        isCurrent ? (current ?? plain) : (plain ?? current)
    }

    /// How far apart, in points, two captures may place a caption and still agree.
    static let agreement: CGFloat = 1

    /// Whether `other` places the caption where this does. Two captures of a bar at rest do; one
    /// taken as the bar moved puts it points away. Only variants both have are compared.
    func agrees(with other: NativeCaptionLook) -> Bool {
        [(plain, other.plain), (current, other.current)].allSatisfy { mine, theirs in
            guard let mine, let theirs else { return true }
            return mine.agrees(with: theirs)
        }
    }

    /// Which look to use for a caption after a capture, given the look in use and an earlier capture
    /// waiting for a second to agree with it. A capture that moves a caption is used only once
    /// another agrees, so one caught as the bar moved never moves the labels. `use` is nil to keep
    /// the look in use.
    static func settle(captured: NativeCaptionLook, held: NativeCaptionLook?, waiting: NativeCaptionLook?)
        -> (use: NativeCaptionLook?, waiting: NativeCaptionLook?) {
        guard let held, !held.agrees(with: captured) else { return (captured, nil) }
        if let waiting, waiting.agrees(with: captured) { return (captured, nil) }
        return (nil, captured)
    }
}

extension NativeCaptionLook.Variant {
    func agrees(with other: Self) -> Bool {
        let limit = NativeCaptionLook.agreement
        return abs(top - other.top) <= limit
            && abs(frame.minX - other.frame.minX) <= limit && abs(frame.minY - other.frame.minY) <= limit
            && abs(frame.width - other.frame.width) <= limit && abs(frame.height - other.frame.height) <= limit
    }
}

/// One caption to match: its centre with the bar at rest and the bar's top and bottom (AX
/// coordinates), the native text it shows, and the name to draw over it.
struct CaptionToMatch {
    let key: String
    let centre: CGPoint
    let barTop: CGFloat
    let barBottom: CGFloat
    let maxWidth: CGFloat
    let covers: String
    let name: String
}

/// What one capture of a display's bar matched, for the debug motion recording.
struct CaptureReport {
    struct Entry {
        let covers: String
        /// The matched look's height in points; nil for a miss.
        let lookHeight: CGFloat?
        /// Why the caption was missed, when the matcher said.
        let miss: String?
    }

    let displayID: CGDirectDisplayID
    /// When the screenshot was asked for, and when it came back (system uptime).
    let asked: TimeInterval
    let taken: TimeInterval
    /// The bar's height, which the captions' looks are kept by.
    let barHeight: CGFloat
    let entries: [Entry]

    init(displayID: CGDirectDisplayID, asked: TimeInterval, taken: TimeInterval, captions: [CaptionToMatch],
         matches: MissionControlCaptionLook.Matches) {
        self.displayID = displayID
        self.asked = asked
        self.taken = taken
        barHeight = captions.first.map { $0.barBottom - $0.barTop } ?? 0
        entries = captions.map { caption in
            let look = matches.looks[caption.key]
            return Entry(covers: caption.covers,
                         lookHeight: look.flatMap { $0.variant(current: $0.wasCurrent)?.frame.height },
                         miss: look == nil ? matches.misses[caption.key] ?? "no reason given" : nil)
        }
    }

    /// "capture display <id> attempt <n> <outcome>, bars <at rest|moved>, bar h <h>, shot in <ms>ms: matched
    /// "<covers>" h <look height>, ...; missed "<covers>" (<reason>), ...", heights in points.
    func line(attempt: Int, outcome: CaptionLooks.Outcome, moved: Bool) -> String {
        let matched = entries.compactMap { entry in
            entry.lookHeight.map { String(format: "\"%@\" h %.1f", entry.covers, $0) }
        }
        let missed = entries.compactMap { entry in entry.miss.map { "\"\(entry.covers)\" (\($0))" } }
        return String(format: "capture display %u attempt %d %@, bars %@, bar h %.0f, shot in %.0fms: ",
                      displayID, attempt, "\(outcome)", moved ? "moved" : "at rest", barHeight,
                      (taken - asked) * 1000)
            + "matched " + (matched.isEmpty ? "none" : matched.joined(separator: ", "))
            + "; missed " + (missed.isEmpty ? "none" : missed.joined(separator: ", "))
    }
}

enum MissionControlCaptionLook {

    private static let log = Logger(subsystem: Constants.AppInfo.bundleId, category: "missionControlLook")

    // Native caption metrics, measured on macOS 26.7: the system font at 14pt, regular weight, in
    // a 24pt pill reaching 17pt above the baseline and 7pt below it.
    static let nativeFontSize: CGFloat = 14
    private static let pillRadius: CGFloat = 6
    private static let bandAbove: CGFloat = 17
    private static let bandBelow: CGFloat = 7
    /// Bar either side of the wider of the native text and the name.
    private static let platePadding: CGFloat = 4
    /// How wide a strip either side of a plate gives the bar's colour on each row.
    private static let edgeBand: CGFloat = 3
    /// How far above and below a caption's centre to look for its text, and how far up from the
    /// bar's bottom: on the built-in display the captions sit well below where the Dock's thumbnail
    /// positions put them, near the bar's bottom.
    private static let searchHalfHeight: CGFloat = 16
    private static let searchAboveBottom: CGFloat = 40
    /// Rows without text that separate the caption from anything above it, such as thumbnails.
    private static let clusterGap: CGFloat = 3
    /// A caption's text, cap height to descender, is between these: anything thinner is a line,
    /// such as the bar's edge, and anything taller is not a caption.
    private static let minTextHeight: CGFloat = 5
    private static let maxTextHeight: CGFloat = 22

    /// Saves each capture, and the labels drawn over it, to Spaceman's caches folder.
    static var isDebugging: Bool {
        UserDefaults.standard.bool(forKey: "missionControlLookDebug")
    }

    // MARK: - Capture

    /// A capture's looks by caption key, and, while the motion recording is on, its report.
    typealias Captured = (looks: [String: NativeCaptionLook], report: CaptureReport?)

    /// Captures the band of the screen holding `captions`, leaving out Spaceman's own windows, and
    /// matches each caption. Nil when the capture fails, as it does without Screen Recording.
    static func capture(
        displayID: CGDirectDisplayID,
        screen: CGRect,
        captions: [CaptionToMatch]
    ) async -> Captured? {
        guard let top = captions.map({ min($0.centre.y - searchHalfHeight, $0.barBottom - searchAboveBottom) }).min(),
              let bottom = captions.map({ max($0.centre.y + searchHalfHeight, $0.barBottom) }).max()
        else { return ([:], nil) }
        let minY = max(0, (top - screen.minY - searchHalfHeight).rounded(.down))
        let maxY = min(screen.height, (bottom - screen.minY + searchHalfHeight).rounded(.up))
        guard maxY > minY else { return ([:], nil) }
        let sourceRect = CGRect(x: 0, y: minY, width: screen.width, height: maxY - minY)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                log.log("No display \(displayID, privacy: .public) to capture")
                return nil
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let own = content.windows.filter { $0.owningApplication?.processID == pid }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.sourceRect = sourceRect
            config.width = Int((sourceRect.width * scale).rounded())
            config.height = Int((sourceRect.height * scale).rounded())
            config.showsCursor = false
            let asked = ProcessInfo.processInfo.systemUptime
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let taken = ProcessInfo.processInfo.systemUptime
            let origin = CGPoint(x: screen.minX, y: screen.minY + minY)
            let pixelScale = CGFloat(image.width) / sourceRect.width
            let matched = matches(in: image, origin: origin, scale: pixelScale, captions: captions)
            let found = matched.looks
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            log.log("""
                Matched \(found.count, privacy: .public) of \(captions.count, privacy: .public) captions \
                on display \(displayID, privacy: .public) in \(elapsed, privacy: .public)ms
                """)
            if isDebugging {
                for caption in captions {
                    let summary = found[caption.key]?.summary ?? "not matched"
                    log.log("\(caption.covers, privacy: .public): \(summary, privacy: .public)")
                }
                saveDebugImages(image, origin: origin, scale: pixelScale, captions: captions, looks: found,
                                name: "display-\(displayID)")
            }
            let report = MissionControlMotionRecorder.isEnabled
                ? CaptureReport(displayID: displayID, asked: asked, taken: taken, captions: captions, matches: matched)
                : nil
            return (found, report)
        } catch {
            log.log("Capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Matching

    /// One native caption as captured, in pixels of the capture.
    private struct Measured {
        let caption: CaptionToMatch
        let inkLeft: Int, inkRight: Int, inkTop: Int, inkBottom: Int
        /// The row just below the first letter.
        let baseline: Int
        let isText: (Int, Int) -> Bool
        let textColor: SIMD3<Double>
        let fontSize: CGFloat
        /// The pill the caption sits in, with exclusive right and bottom edges, when it is the current space's.
        let pill: Pill?
        /// Where the Dock's thumbnails put the caption's centre, for the log.
        let centreY: Int

        var inkCentre: Double { Double(inkLeft + inkRight + 1) / 2 }
        var inkWidth: Int { inkRight - inkLeft + 1 }
    }

    /// A caption measured in the capture, or why it couldn't be.
    private enum Measurement {
        case found(Measured)
        case missed(String)
    }

    private struct Pill {
        let left: Int, right: Int, top: Int, bottom: Int
        let color: SIMD3<Double>
    }

    /// A bar's current-space pill relative to its caption's text, to draw behind any caption.
    private struct PillStyle {
        let padding: Int, above: Int, below: Int
        let color: SIMD3<Double>
    }

    /// What matching a capture's captions found: looks, and why each caption with none was missed, by key.
    struct Matches {
        var looks: [String: NativeCaptionLook] = [:]
        var misses: [String: String] = [:]
    }

    /// Matches each caption in `image`, whose top-left pixel sits at `origin` (AX coordinates)
    /// with `scale` pixels to the point.
    static func looks(
        in image: CGImage,
        origin: CGPoint,
        scale: CGFloat,
        captions: [CaptionToMatch]
    ) -> [String: NativeCaptionLook] {
        matches(in: image, origin: origin, scale: scale, captions: captions).looks
    }

    /// `looks(in:origin:scale:captions:)`, with why each caption it found no look for missed.
    static func matches(
        in image: CGImage,
        origin: CGPoint,
        scale: CGFloat,
        captions: [CaptionToMatch]
    ) -> Matches {
        var result = Matches()
        guard let pixels = Pixels(image) else {
            for caption in captions { result.misses[caption.key] = "capture unreadable" }
            return result
        }
        var measured: [Measured] = []
        for caption in captions {
            switch measure(caption, in: pixels, origin: origin, scale: scale) {
            case .found(let found): measured.append(found)
            case .missed(let reason): result.misses[caption.key] = reason
            }
        }
        // Each bar has one current space, whose pill the other captions take if it becomes theirs.
        let style = measured.lazy.compactMap { found in
            found.pill.map {
                PillStyle(padding: found.inkLeft - $0.left, above: found.baseline - $0.top,
                          below: $0.bottom - found.baseline, color: $0.color)
            }
        }.first
        for caption in measured {
            let plain = plainVariant(caption, style: style, pixels: pixels, origin: origin, scale: scale)
            let current = (caption.pill != nil || style != nil)
                ? pillVariant(caption, style: style, pixels: pixels, origin: origin, scale: scale)
                : nil
            guard plain != nil || current != nil else {
                result.misses[caption.caption.key] = "no plate could be drawn"
                continue
            }
            let summary = [
                caption.pill.map { "pill \(describe($0.color)) \($0.right - $0.left)x\($0.bottom - $0.top)px" }
                    ?? "plain",
                "text \(describe(caption.textColor)) \(caption.fontSize)pt",
                "ink \(caption.inkLeft)-\(caption.inkRight)x\(caption.inkTop)-\(caption.inkBottom)",
                "baseline \(caption.baseline) (Dock's centre \(caption.centreY))",
                "plain \(plain.map { "\($0.frame.size)" } ?? "none")",
                "in pill \(current.map { "\($0.frame.size)" } ?? "none")",
            ].joined(separator: ", ")
            result.looks[caption.caption.key] = NativeCaptionLook(
                plain: plain, current: current, wasCurrent: caption.pill != nil, summary: summary)
        }
        return result
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func measure(
        _ caption: CaptionToMatch,
        in pixels: Pixels,
        origin: CGPoint,
        scale: CGFloat
    ) -> Measurement {
        func px(_ points: CGFloat) -> Int { Int((points * scale).rounded()) }
        let centreX = px(caption.centre.x - origin.x)
        let centreY = px(caption.centre.y - origin.y)
        let halfWidth = px(max(caption.maxWidth, 20) / 2)
        // A caption can be partly or wholly off the screen, as when hover-expanded thumbnails scroll.
        let left = max(0, centreX - halfWidth), right = min(pixels.width, centreX + halfWidth)
        let barBottom = px(caption.barBottom - origin.y)
        let upper = max(0, min(centreY - px(searchHalfHeight), barBottom - px(searchAboveBottom)))
        let lower = min(pixels.height, max(centreY + px(searchHalfHeight), barBottom))
        guard right - left > 8, lower - upper > 8 else { return .missed("search window off the capture") }
        let columns = left..<right, rows = upper..<lower

        // The text is the pixels furthest from the caption's background, lighter or darker.
        var levels: [Double] = []
        levels.reserveCapacity(columns.count * rows.count)
        for y in rows { for x in columns { levels.append(pixels.luminance(x, y)) } }
        levels.sort()
        let background = levels[levels.count / 2]
        guard let brightest = levels.last, let darkest = levels.first else { return .missed("no pixels") }
        let textIsLight = brightest - background >= background - darkest
        let contrast = textIsLight ? brightest - background : background - darkest
        guard contrast > 40 else { return .missed(String(format: "contrast %.0f, not over 40", contrast)) }
        let threshold = textIsLight ? background + contrast / 2 : background - contrast / 2
        let isText: (Int, Int) -> Bool = { x, y in
            let level = pixels.luminance(x, y)
            return textIsLight ? level > threshold : level < threshold
        }

        // The caption is the lowest line of text in the window: anything above it, such as the
        // bottom of a thumbnail, is separated from it by rows of plain bar. Lines too thin to be
        // text, such as the bar's lit bottom edge, are passed over.
        var clusters: [ClosedRange<Int>] = []
        for y in rows.reversed() where columns.contains(where: { isText($0, y) }) {
            if let last = clusters.last, last.lowerBound - y <= px(clusterGap) {
                clusters[clusters.count - 1] = y...last.upperBound
            } else {
                clusters.append(y...y)
            }
        }
        guard let cluster = clusters.first(where: { $0.upperBound - $0.lowerBound + 1 >= px(minTextHeight) }) else {
            return .missed(String(format: "no text %.0fpt tall", minTextHeight))
        }
        guard cluster.upperBound - cluster.lowerBound < px(maxTextHeight) else {
            let height = CGFloat(cluster.upperBound - cluster.lowerBound + 1) / scale
            return .missed(String(format: "lowest text %.1fpt tall, not under %.0f", height, maxTextHeight))
        }
        let clusterTop = cluster.lowerBound, lowest = cluster.upperBound
        let textRows = Array(cluster)
        var inkLeft = Int.max, inkRight = -1
        for y in textRows {
            for x in columns where isText(x, y) {
                inkLeft = min(inkLeft, x); inkRight = max(inkRight, x)
            }
        }
        let inkTop = clusterTop, inkBottom = lowest
        guard inkRight >= inkLeft else { return .missed("no ink") }
        // Text running into the screen's edge is a caption partly off it: its look would be wrong.
        let cutLeft = centreX - halfWidth < 0 && inkLeft <= left + 1
        let cutRight = centreX + halfWidth > pixels.width && inkRight >= right - 2
        if cutLeft || cutRight { return .missed("cut off at the screen's edge") }
        // The baseline is the bottom of the first letter, which has no descender ("Desktop").
        var baseline = inkTop
        for x in inkLeft..<min(inkRight + 1, inkLeft + px(3)) {
            for y in inkTop...inkBottom where isText(x, y) { baseline = max(baseline, y + 1) }
        }

        // A pill shows as a different colour between the text and where the bar would be.
        let probeY = min(max(baseline - px(5), 0), pixels.height - 1)
        var inside: (x: Int, color: SIMD3<Double>)?
        var outside: SIMD3<Double>?
        if inkLeft - px(17) >= 0 {
            inside = (inkLeft - px(5), pixels.color(inkLeft - px(5), probeY))
            outside = pixels.color(inkLeft - px(17), probeY)
        } else if inkRight + px(17) < pixels.width {
            inside = (inkRight + px(5), pixels.color(inkRight + px(5), probeY))
            outside = pixels.color(inkRight + px(17), probeY)
        }
        var pill: Pill?
        if let inside, let outside, distance(inside.color, outside) > 20 {
            func isPill(_ x: Int, _ y: Int) -> Bool { distance(pixels.color(x, y), inside.color) < 14 }
            var left = min(inkLeft - px(3), inside.x)
            while left > 0, isPill(left - 1, probeY) { left -= 1 }
            var right = max(inkRight + px(3), inside.x)
            while right < pixels.width - 1, isPill(right + 1, probeY) { right += 1 }
            var top = probeY
            while top > 0, isPill(inside.x, top - 1) { top -= 1 }
            var bottom = probeY
            while bottom < pixels.height - 1, isPill(inside.x, bottom + 1) { bottom += 1 }
            var samples: [SIMD3<Double>] = []
            let padding = Array((left + px(3))..<max(left + px(3), inkLeft - px(2)))
                + Array((inkRight + px(2) + 1)..<max(inkRight + px(2) + 1, right - px(3)))
            for y in (top + px(4))..<max(top + px(4), bottom - px(4)) {
                for x in padding where !isText(x, y) { samples.append(pixels.color(x, y)) }
            }
            pill = Pill(left: left, right: right + 1, top: top, bottom: bottom + 1,
                        color: samples.isEmpty ? inside.color : mean(samples))
        }

        // The text's colour is its most extreme pixel; its size, its width against the system font's.
        var textColor = pixels.color(inkLeft, inkTop)
        var extreme = textIsLight ? -Double.infinity : Double.infinity
        for y in inkTop...inkBottom {
            for x in inkLeft...inkRight {
                let level = pixels.luminance(x, y)
                if textIsLight ? level > extreme : level < extreme {
                    extreme = level
                    textColor = pixels.color(x, y)
                }
            }
        }
        let nativeInkWidth = CGFloat(inkRight - inkLeft + 1) / scale
        let reference = inkBounds(of: caption.covers, size: nativeFontSize).width
        let fontSize = reference > 0
            ? min(max((nativeFontSize * nativeInkWidth / reference * 4).rounded() / 4, 10), 20)
            : nativeFontSize
        return .found(Measured(
            caption: caption, inkLeft: inkLeft, inkRight: inkRight, inkTop: inkTop, inkBottom: inkBottom,
            baseline: baseline, isText: isText, textColor: textColor, fontSize: fontSize, pill: pill,
            centreY: centreY))
    }

    /// The caption on a plain stretch of bar: a patch of bar wide enough to hide the native text and
    /// hold the name, and as large as the pill, so it hides the pill too if Mission Control has moved
    /// it here a moment before Spaceman follows. Where the caption sits in the pill, the bar is read
    /// from beside the pill.
    private static func plainVariant(
        _ found: Measured,
        style: PillStyle?,
        pixels: Pixels,
        origin: CGPoint,
        scale: CGFloat
    ) -> NativeCaptionLook.Variant? {
        func px(_ points: CGFloat) -> Int { Int((points * scale).rounded()) }
        let line = nameLine(found, space: pixels.colorSpace)
        let nameWidth = Double(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width * scale)
        let nativeWidth = Double(found.inkWidth)
        let wanted = max(nativeWidth, nameWidth) + 2 * Double(platePadding * scale)
        let pillWidth = style.map { Double(found.inkWidth + 2 * $0.padding + 2) } ?? 0
        let width = max(min(wanted, Double(found.caption.maxWidth * scale)), nativeWidth + 2, pillWidth)
        let boxLeft = Int((found.inkCentre - width / 2).rounded(.down))
        let boxRight = Int((found.inkCentre + width / 2).rounded(.up))
        let boxTop = style.map { found.baseline - $0.above - 1 } ?? found.baseline - px(bandAbove)
        let boxBottom = style.map { found.baseline + $0.below + 1 } ?? found.baseline + px(bandBelow)
        let boxWidth = boxRight - boxLeft, boxHeight = boxBottom - boxTop
        guard boxWidth > 0, boxHeight > 0, let context = context(boxWidth, boxHeight, pixels.colorSpace),
              let data = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }

        let band = max(px(edgeBand), 1)
        let leftEdge = found.pill.map { $0.left - 2 } ?? boxLeft
        let rightEdge = found.pill.map { $0.right + 2 } ?? boxRight
        let leftX = Double(leftEdge) - Double(band) / 2, rightX = Double(rightEdge) + Double(band) / 2
        for row in 0..<boxHeight {
            let y = min(max(boxTop + row, 0), pixels.height - 1)
            // Text beside the plate is left out; a row that is all text either side is a line across
            // the bar, such as its lit edge, and is the bar's colour there.
            let leftBand = (leftEdge - band)..<leftEdge, rightBand = rightEdge..<(rightEdge + band)
            let leftColor = edgeColor(pixels, columns: leftBand, row: y, isText: found.isText)
            let rightColor = edgeColor(pixels, columns: rightBand, row: y, isText: found.isText)
            let lineColor = leftColor == nil && rightColor == nil
                ? edgeColor(pixels, columns: leftBand, row: y) { _, _ in false } : nil
            guard let left = leftColor ?? rightColor ?? lineColor, let right = rightColor ?? leftColor ?? lineColor
            else { return nil }
            for column in 0..<boxWidth {
                let x = Double(boxLeft + column) + 0.5
                let fraction = min(max((x - leftX) / (rightX - leftX), 0), 1)
                let color = left * (1 - fraction) + right * fraction
                let index = (row * boxWidth + column) * 4
                data[index] = UInt8(min(max(color.x.rounded(), 0), 255))
                data[index + 1] = UInt8(min(max(color.y.rounded(), 0), 255))
                data[index + 2] = UInt8(min(max(color.z.rounded(), 0), 255))
                data[index + 3] = 255
            }
        }
        return finish(context, line: line, found: found, centreX: found.inkCentre, boxLeft: boxLeft, boxTop: boxTop,
                      boxBottom: boxBottom, origin: origin, scale: scale)
    }

    /// The caption as the current space's: a pill as large as the native one, or as the name needs.
    /// A caption captured in the pill keeps that pill's exact shape; the others take `style`'s.
    private static func pillVariant(
        _ found: Measured,
        style: PillStyle?,
        pixels: Pixels,
        origin: CGPoint,
        scale: CGFloat
    ) -> NativeCaptionLook.Variant? {
        guard let colorValue = found.pill?.color ?? style?.color,
              let padding = found.pill.map({ found.inkLeft - $0.left }) ?? style?.padding,
              let top = found.pill?.top ?? style.map({ found.baseline - $0.above }),
              let bottom = found.pill?.bottom ?? style.map({ found.baseline + $0.below }),
              let fill = cgColor(colorValue, in: pixels.colorSpace)
        else { return nil }
        let line = nameLine(found, space: pixels.colorSpace)
        let nameWidth = Double(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width * scale)
        let nativeWidth = found.pill.map { Double($0.right - $0.left) } ?? Double(found.inkWidth + 2 * padding)
        let middle = found.pill.map { Double($0.left + $0.right) / 2 } ?? found.inkCentre
        let width = max(nativeWidth, nameWidth + 2 * Double(padding))
        let boxLeft = Int((middle - width / 2).rounded(.down)) - 1
        let boxRight = Int((middle + width / 2).rounded(.up)) + 1
        let boxTop = top - 1, boxBottom = bottom + 1
        guard boxRight > boxLeft, boxBottom > boxTop,
              let context = context(boxRight - boxLeft, boxBottom - boxTop, pixels.colorSpace)
        else { return nil }
        // Half a pixel larger all round than the native pill, to cover its antialiased edge.
        let rect = CGRect(
            x: middle - width / 2 - 0.5 - Double(boxLeft),
            y: Double(boxBottom - bottom) - 0.5,
            width: width + 1,
            height: Double(bottom - top) + 1)
        let radius = pillRadius * scale
        context.setFillColor(fill)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        return finish(context, line: line, found: found, centreX: middle, boxLeft: boxLeft, boxTop: boxTop,
                      boxBottom: boxBottom, origin: origin, scale: scale)
    }

    private static func context(_ width: Int, _ height: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func nameLine(_ found: Measured, space: CGColorSpace) -> CTLine {
        textLine(found.caption.name, size: found.fontSize, color: cgColor(found.textColor, in: space))
    }

    /// Draws the name centred on `centreX` on the native baseline, and places the label.
    // swiftlint:disable:next function_parameter_count
    private static func finish(
        _ context: CGContext,
        line: CTLine,
        found: Measured,
        centreX: Double,
        boxLeft: Int,
        boxTop: Int,
        boxBottom: Int,
        origin: CGPoint,
        scale: CGFloat
    ) -> NativeCaptionLook.Variant? {
        let nameInk = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: (CGFloat(centreX) - CGFloat(boxLeft)) / scale - nameInk.midX,
            y: CGFloat(boxBottom - found.baseline) / scale)
        CTLineDraw(line, context)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        let caption = found.caption
        let frame = CGRect(
            x: origin.x + CGFloat(boxLeft) / scale - caption.centre.x,
            y: origin.y + CGFloat(boxTop) / scale - caption.centre.y,
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale)
        return NativeCaptionLook.Variant(
            frame: frame, top: origin.y + CGFloat(boxTop) / scale - caption.barTop, image: image)
    }

    /// The bar's colour on `row` across `columns`: the median of its pixels, leaving out text.
    private static func edgeColor(
        _ pixels: Pixels,
        columns: Range<Int>,
        row: Int,
        isText: (Int, Int) -> Bool
    ) -> SIMD3<Double>? {
        let colors = columns.clamped(to: 0..<pixels.width)
            .filter { !isText($0, row) }
            .map { pixels.color($0, row) }
        guard !colors.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return SIMD3(median(colors.map(\.x)), median(colors.map(\.y)), median(colors.map(\.z)))
    }

    // MARK: - Text

    private static func textLine(_ text: String, size: CGFloat, color: CGColor?) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size)]
        if let color {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func inkBounds(of text: String, size: CGFloat) -> CGRect {
        CTLineGetBoundsWithOptions(textLine(text, size: size, color: nil), .useGlyphPathBounds)
    }

    // MARK: - Colour

    private static func distance(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> Double {
        let difference = first - second
        return (difference * difference).sum().squareRoot()
    }

    private static func mean(_ colors: [SIMD3<Double>]) -> SIMD3<Double> {
        colors.reduce(SIMD3<Double>(repeating: 0), +) / Double(colors.count)
    }

    private static func cgColor(_ color: SIMD3<Double>, in space: CGColorSpace) -> CGColor? {
        CGColor(colorSpace: space, components: [color.x / 255, color.y / 255, color.z / 255, 1])
    }

    private static func describe(_ color: SIMD3<Double>) -> String {
        "(\(Int(color.x.rounded())),\(Int(color.y.rounded())),\(Int(color.z.rounded())))"
    }

    // MARK: - Debugging

    /// Writes the capture, and the capture with the labels drawn where they go at rest.
    private static func saveDebugImages(
        _ image: CGImage,
        origin: CGPoint,
        scale: CGFloat,
        captions: [CaptionToMatch],
        looks: [String: NativeCaptionLook],
        name: String
    ) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let folder = caches.appendingPathComponent(Constants.AppInfo.bundleId, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for caption in captions {
            guard let look = looks[caption.key]?.variant(current: looks[caption.key]?.wasCurrent ?? false)
            else { continue }
            let left = (caption.centre.x + look.frame.minX - origin.x) * scale
            let top = (caption.barTop + look.top - origin.y) * scale
            let size = CGSize(width: look.frame.width * scale, height: look.frame.height * scale)
            context.draw(look.image, in: CGRect(x: left, y: height - top - size.height, width: size.width,
                                                height: size.height))
        }
        write(image, to: folder.appendingPathComponent("\(name)-capture.png"))
        if let matched = context.makeImage() {
            write(matched, to: folder.appendingPathComponent("\(name)-labels.png"))
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - Pixels

/// A capture's pixels as 8-bit RGB, in the capture's own colour space, read from the top-left.
private struct Pixels {
    let width: Int
    let height: Int
    let colorSpace: CGColorSpace
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        let candidates = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in candidates where space.model == .rgb {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            if drawn {
                self.width = width
                self.height = height
                self.colorSpace = space
                self.bytes = bytes
                return
            }
        }
        return nil
    }

    /// The pixel `x` across and `y` down from the top-left, as 0–255 RGB.
    func color(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let index = (y * width + x) * 4
        return SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2]))
    }

    func luminance(_ x: Int, _ y: Int) -> Double {
        let color = color(x, y)
        return 0.299 * color.x + 0.587 * color.y + 0.114 * color.z
    }
}
