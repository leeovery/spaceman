//
//  MissionControlLabels+Strips.swift
//  Spaceman
//
//  Labels on a magnifying bar drawn from its caption strip: captured once the hover settles, kept, and cropped
//  under each label wherever its thumbnail has it.
//

import AppKit

extension MissionControlLabels {

    /// A strip's capture whose shot is back: what it brought, the bar motion count when it started, and its screen.
    struct ShotStrip {
        let capture: CaptionStrips.Capture
        let shot: MissionControlCaptionLook.StripShot
        let motion: Int
        let screen: CGRect
    }

    /// Captures a magnifying bar's caption row, per screen and bar height until two captures agree, once the bar has
    /// been still, the thumbnails done resizing and the same thumbnail hovered for a moment: the line of a caption
    /// caught moving is measured off its thumbnail's middle.
    func captureStripsIfDue(_ measured: [BarLayout], now: TimeInterval) {
        guard labelStyle == .nativeLook, !isCapturingStrip,
              let steadySince = CaptionStrips.steadySince(stillSince: stillSince, resizedAt: thumbnailsResizedAt)
        else { return }
        for bar in measured where magnification.magnifies(bar) {
            guard Self.retraction(bar: bar.frame, screen: bar.screen) <= Self.restSlack,
                  let place = shownLabels(on: bar, at: now).hovered, bar.buttons.indices.contains(place),
                  let key = captionStrips.key(for: bar),
                  var capture = captionStrips.capture(
                    key: key, hovered: place, thumbnail: bar.buttons[place].frame, at: now, steadySince: steadySince),
                  // Read as a look's capture reads it, once it is due: what the screen shows as it is shot.
                  let background = CaptionLooks.currentBackgrounds()[CaptionLooks.screenKey(bar.screen)]
            else { continue }
            capture.background = background
            startStripCapture(capture, of: bar)
            return
        }
    }

    private func startStripCapture(_ capture: CaptionStrips.Capture, of bar: BarLayout) {
        isCapturingStrip = true
        let thumbnail = bar.buttons[capture.place]
        // The caption is looked for as far as a thumbnail's width either side, and text left beside it as far as two.
        // Its depth is measured from the bar's top where the overlay puts it, so a bar resting a little short of
        // fully in isn't lifted twice.
        let hovered = CaptionToMatch(
            key: capture.key, centre: Self.captionCentre(below: thumbnail.frame),
            barTop: CaptionStrips.depthTop(of: bar), barBottom: bar.frame.maxY, maxWidth: 2 * thumbnail.frame.width,
            covers: thumbnail.title, name: "")
        let motion = barMotionCount
        let displayID = bar.displayID, screen = bar.screen, background = capture.background
        let owner = WeakOwner(self)
        Task.detached(priority: .userInitiated) {
            let shot = await MissionControlCaptionLook.captureStrip(
                displayID: displayID, screen: screen, hovered: hovered, background: background)
            DispatchQueue.main.async {
                // An earlier session's shot would take the place of this session's own.
                guard let labels = owner.labels, labels.captionStrips.isCurrent(capture) else { return }
                if let shot {
                    labels.shotStrip = ShotStrip(capture: capture, shot: shot, motion: motion, screen: screen)
                } else {
                    labels.finishStripCapture(capture, nil, motion: motion, thumbnailStayed: true)
                }
            }
        }
    }

    /// Takes in `shot` once `reading` was read after it, telling whether its hovered thumbnail moved meanwhile.
    func finishStripCapture(_ shot: ShotStrip, reading: DockReader.Reading) {
        guard reading.time > shot.shot.taken else { return }
        let place = shot.capture.place
        let bar = reading.layouts.first { $0.screen == shot.screen }
        let frame = bar.flatMap { $0.buttons.indices.contains(place) ? $0.buttons[place].frame : nil }
        shotStrip = nil
        finishStripCapture(
            shot.capture, shot.shot.captured, motion: shot.motion,
            thumbnailStayed: CaptionStrips.thumbnailStayed(at: shot.capture.thumbnail, now: frame))
    }

    /// Takes in a strip's capture, and writes its strip to disk once two captures agree on it.
    private func finishStripCapture(
        _ capture: CaptionStrips.Capture, _ result: MissionControlCaptionLook.StripCapture?, motion: Int,
        thumbnailStayed: Bool
    ) {
        let outcome = captionStrips.finish(
            capture, result, moved: motion != barMotionCount || !thumbnailStayed,
            at: ProcessInfo.processInfo.systemUptime)
        guard outcome != .stale else { return }
        isCapturingStrip = false
        record("strip capture \(capture.key) hovered \(capture.place + 1): \(outcome)")
        guard outcome == .kept, let strip = captionStrips.kept[capture.key] else { return }
        CaptionStripStore.save(strip, key: capture.key)
    }

    /// How a magnifying bar's labels are drawn this frame, with `shown` its labels shown. Each caption's name on the
    /// bar is rendered in the strip's style ahead of its thumbnail's hover, once a session and again when the style
    /// changes.
    func stripDrawing(for bar: BarLayout, shown: ShownLabels, at time: TimeInterval) -> StripDrawing {
        let hovered = shown.hovered
        let screen = CaptionLooks.screenKey(bar.screen), height = bar.frame.height
        let drawing = captionStrips.drawing(
            for: bar, hovered: hovered, colors: { self.captionLooks.measuredColors(onScreen: screen, height: height) },
            at: time)
        if let key = drawing.key, preparedStyles[key] != drawing.style,
           let scale = drawing.strip?.scale ?? captionStrips.scale(of: bar) {
            preparedStyles[key] = drawing.style
            for caption in bar.captions {
                _ = stripNames.image(for: caption.name, style: drawing.style, scale: scale)
                _ = stripNames.ink(of: caption.covers, style: drawing.style)
            }
        }
        return drawing
    }

    /// `label` on `fallback`'s plate, centred where a strip would centre it, its names measured in `style`, starting
    /// no higher than `ceiling` below the bar's top.
    func fallbackPlate(
        for label: MissionControlLabel, fallback: StripFallback, style: CaptionStrip.TextStyle, ceiling: CGFloat
    ) -> (plate: LabelPlate, origin: CGPoint) {
        fallback.plate(
            nameWidth: stripNames.ink(of: label.name, style: style).width,
            covers: stripNames.ink(of: label.covers, style: style), thumbnailMidX: label.centre.x,
            captionCentreY: label.centre.y, barTop: label.screen.minY, ceiling: ceiling)
    }

    /// `label` drawn from `strip` in `style`, centred on the native caption's ink under its thumbnail, starting no
    /// higher than `ceiling` below the bar's top: the face, and the label's top-left in AX coordinates.
    func stripFace(
        for label: MissionControlLabel, strip: CaptionStrip, style: CaptionStrip.TextStyle, ceiling: CGFloat
    ) -> (face: StripFace, origin: CGPoint)? {
        guard let name = stripNames.image(for: label.name, style: style, scale: strip.scale) else { return nil }
        let covers = stripNames.ink(of: label.covers, style: style)
        let layout = strip.layout(name: name, coversWidth: covers.width, ceiling: ceiling)
        let placed = strip.placement(
            centreX: strip.inkCentre(underThumbnailAt: label.centre.x, inkOffset: covers.offset),
            layout: layout, screenLeft: label.screen.minX)
        return (StripFace(strip: strip.image, crop: placed.crop, name: name.image, layout: layout),
                CGPoint(x: placed.left, y: label.screen.minY + strip.top + layout.cut))
    }
}
