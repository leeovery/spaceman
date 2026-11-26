//
//  MissionControlLabels+Strips.swift
//  Spaceman
//
//  Labels on a magnifying bar drawn from its caption strip: captured once the hover settles, kept, and cropped
//  under each label wherever its thumbnail has it.
//

import AppKit

extension MissionControlLabels {

    /// Captures a magnifying bar's caption row, once a session per screen and bar height and once more to measure the
    /// current space's pill, once the bar has been still and the same thumbnail hovered for a moment. It doesn't wait
    /// for the thumbnails to stop resizing: the bar's background doesn't move with them, and the one caption, under
    /// the hovered thumbnail, is found wherever it has got to.
    func captureStripsIfDue(_ measured: [BarLayout], selected: [Int?], now: TimeInterval) {
        guard labelStyle == .nativeLook, !isCapturingStrip, let stillSince else { return }
        for (index, bar) in measured.enumerated() where magnification.magnifies(bar) {
            guard Self.retraction(bar: bar.frame, screen: bar.screen) <= Self.restSlack,
                  case .only(let place) = shownLabels(on: bar), bar.buttons.indices.contains(place),
                  let key = captionStrips.key(for: bar), let background = captionStrips.background(forKey: key)
            else { continue }
            let current = bar.spaceIDs.indices.contains(place) && Self.isCurrent(
                spaceID: bar.spaceIDs[place], selected: index < selected.count ? selected[index] : nil, on: bar,
                currentSpaceIDs: currentSpaceIDs)
            guard let capture = captionStrips.capture(
                key: key, hovered: place, current: current, at: now, stillSince: stillSince)
            else { continue }
            startStripCapture(capture, of: bar, background: background)
            return
        }
    }

    private func startStripCapture(_ capture: CaptionStrips.Capture, of bar: BarLayout, background: String) {
        isCapturingStrip = true
        let thumbnail = bar.buttons[capture.place]
        // The thumbnails can resize between this reading and the shot: the caption is looked for as far as a
        // thumbnail's width either side. Its depth is measured from the screen's top, where the labels are drawn,
        // so a bar the Dock reports a little off its place still gives the depth they go at.
        let hovered = CaptionToMatch(
            key: capture.key, centre: Self.captionCentre(below: thumbnail.frame), barTop: bar.screen.minY,
            barBottom: bar.frame.maxY, maxWidth: 2 * thumbnail.frame.width, covers: thumbnail.title, name: "")
        let motion = barMotionCount
        let displayID = bar.displayID, screen = bar.screen
        let owner = WeakOwner(self)
        Task.detached(priority: .userInitiated) {
            let result = await MissionControlCaptionLook.captureStrip(
                displayID: displayID, screen: screen, hovered: hovered, background: background)
            DispatchQueue.main.async {
                owner.labels?.finishStripCapture(capture, result, motion: motion)
            }
        }
    }

    /// Takes in a strip's capture, and writes it to disk once it is drawn.
    private func finishStripCapture(
        _ capture: CaptionStrips.Capture, _ result: MissionControlCaptionLook.StripCapture?, motion: Int
    ) {
        let outcome = captionStrips.finish(
            capture, result, barMoved: motion != barMotionCount, at: ProcessInfo.processInfo.systemUptime)
        guard outcome != .stale else { return }
        isCapturingStrip = false
        record("strip capture \(capture.key) hovered \(capture.place + 1)\(capture.current ? " in its pill" : ""): "
               + "\(outcome)")
        guard outcome == .kept, let strip = captionStrips.kept[capture.key] else { return }
        CaptionStripStore.save(strip, key: capture.key)
    }

    /// How a magnifying bar's labels are drawn this frame, with `shown` its labels shown. Each caption's name on the
    /// bar is rendered in the strip's style ahead of its thumbnail's hover, once a session and again when the style
    /// changes.
    func stripDrawing(for bar: BarLayout, shown: ShownLabels, at time: TimeInterval) -> StripDrawing {
        var hovered: Int?
        if case .only(let place) = shown { hovered = place }
        let screen = CaptionLooks.screenKey(bar.screen), height = bar.frame.height
        let drawing = captionStrips.drawing(
            for: bar, hovered: hovered, colors: { self.captionLooks.measuredColors(onScreen: screen, height: height) },
            at: time)
        if let key = drawing.key, preparedStyles[key] != drawing.style,
           let scale = drawing.strip?.scale ?? captionStrips.scale(of: bar) {
            preparedStyles[key] = drawing.style
            for caption in bar.captions {
                _ = stripNames.image(for: caption.name, style: drawing.style.text, scale: scale)
                _ = stripNames.ink(of: caption.covers, style: drawing.style.text)
            }
        }
        return drawing
    }

    /// `label` drawn from `strip` in `style`, centred on the native caption's ink under its thumbnail: the face, and
    /// the label's left edge.
    func stripFace(
        for label: MissionControlLabel, strip: CaptionStrip, style: CaptionStrip.Style, current: Bool
    ) -> (face: StripFace, left: CGFloat)? {
        guard let name = stripNames.image(for: label.name, style: style.text, scale: strip.scale) else { return nil }
        let covers = stripNames.ink(of: label.covers, style: style.text)
        let layout = strip.layout(name: name, coversWidth: covers.width, style: style, current: current)
        let placed = strip.placement(
            centreX: strip.inkCentre(underThumbnailAt: label.centre.x, inkOffset: covers.offset),
            width: layout.size.width, screenLeft: label.screen.minX)
        return (StripFace(strip: strip.image, crop: placed.crop, name: name.image, layout: layout), placed.left)
    }
}
