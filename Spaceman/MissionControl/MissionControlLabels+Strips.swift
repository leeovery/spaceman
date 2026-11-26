//
//  MissionControlLabels+Strips.swift
//  Spaceman
//
//  Labels on a magnifying bar drawn from its caption strip: captured as soon as the bar is in, kept, and cropped
//  under each label wherever its thumbnail has it.
//

import AppKit

extension MissionControlLabels {

    /// Captures a magnifying bar's caption row, once a session per screen and bar height and once more to measure the
    /// current space's pill, as soon as the bar is at rest with a thumbnail hovered. It doesn't wait for the
    /// thumbnails to stop resizing: the bar's background doesn't move with them, and the one caption, under the
    /// hovered thumbnail, is found wherever it has got to.
    func captureStripsIfDue(_ measured: [BarLayout], selected: [Int?]) {
        guard labelStyle == .nativeLook else { return }
        let hovered = measured.map { shownLabels(on: $0) }
        if hovered != lastHovered {
            hoverCount &+= 1
            lastHovered = hovered
        }
        guard !isCapturingStrip else { return }
        for (index, bar) in measured.enumerated() where magnification.magnifies(bar) {
            guard abs(bar.frame.minY - bar.screen.minY) < 0.5, case .only(let place) = hovered[index],
                  bar.buttons.indices.contains(place)
            else { continue }
            let current = bar.spaceIDs.indices.contains(place) && Self.isCurrent(
                spaceID: bar.spaceIDs[place], selected: index < selected.count ? selected[index] : nil, on: bar,
                currentSpaceIDs: currentSpaceIDs)
            guard let capture = captionStrips.capture(of: bar, hovered: place, current: current),
                  let background = captionStrips.background(of: bar)
            else { continue }
            startStripCapture(capture, of: bar, background: background)
            return
        }
    }

    private func startStripCapture(_ capture: CaptionStrips.Capture, of bar: BarLayout, background: String) {
        isCapturingStrip = true
        let thumbnail = bar.buttons[capture.place]
        // The thumbnails can resize between this reading and the shot: the caption is looked for as far as a
        // thumbnail's width either side.
        let hovered = CaptionToMatch(
            key: capture.key, centre: Self.captionCentre(below: thumbnail.frame), barTop: bar.frame.minY,
            barBottom: bar.frame.maxY, maxWidth: 2 * thumbnail.frame.width, covers: thumbnail.title, name: "")
        let motion = (barMotionCount, hoverCount)
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

    /// Keeps a strip's capture, unless it is from an earlier session or the bar moved, or another thumbnail was
    /// hovered, while it ran; and writes it to disk.
    private func finishStripCapture(
        _ capture: CaptionStrips.Capture, _ result: MissionControlCaptionLook.StripCapture?, motion: (Int, Int)
    ) {
        let outcome = captionStrips.finish(capture, result, moved: motion != (barMotionCount, hoverCount))
        guard outcome != .stale else { return }
        isCapturingStrip = false
        record("strip capture \(capture.key) hovered \(capture.place + 1)\(capture.current ? " in its pill" : ""): "
               + "\(outcome)")
        guard outcome == .kept, let strip = captionStrips.kept[capture.key] else { return }
        CaptionStripStore.save(strip, key: capture.key)
    }

    /// How a magnifying bar's labels are drawn from `strip`, or until it lands, from what was measured on its screen;
    /// with every caption's name on the bar rendered in that style ahead of its thumbnail's hover.
    func stripStyle(for bar: BarLayout, strip: CaptionStrip?) -> CaptionStrip.Style {
        let measured: CaptionLooks.Colors = strip?.pill != nil ? (nil, nil)
            : captionLooks.measuredColors(onScreen: CaptionLooks.screenKey(bar.screen), height: bar.frame.height)
        let style = CaptionStrip.style(of: strip, measured: measured)
        guard let scale = strip?.scale ?? captionStrips.scale(of: bar) else { return style }
        for caption in bar.captions {
            _ = stripNames.image(for: caption.name, style: style.text, scale: scale)
            _ = stripNames.inkWidth(of: caption.covers, style: style.text)
        }
        return style
    }

    /// `label` drawn from `strip` in `style`, centred where it is placed: the face, and the label's left edge.
    func stripFace(
        for label: MissionControlLabel, strip: CaptionStrip, style: CaptionStrip.Style, current: Bool
    ) -> (face: StripFace, left: CGFloat)? {
        guard let name = stripNames.image(for: label.name, style: style.text, scale: strip.scale) else { return nil }
        let layout = strip.layout(
            name: name, coversWidth: stripNames.inkWidth(of: label.covers, style: style.text), style: style,
            current: current)
        let placed = strip.placement(centreX: label.centre.x, width: layout.size.width, screenLeft: label.screen.minX)
        return (StripFace(strip: strip.image, crop: placed.crop, name: name.image, layout: layout), placed.left)
    }
}
