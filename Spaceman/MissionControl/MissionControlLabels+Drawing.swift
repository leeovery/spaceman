//
//  MissionControlLabels+Drawing.swift
//  Spaceman
//
//  Turns the measured bars into the labels the overlay draws, each frame.
//

import AppKit

extension MissionControlLabels {

    /// Draws every bar's labels with the bar `retraction` of the way off its screen, or moving with
    /// `slide`. The labels stay opaque all the way: a fading label would show the native caption
    /// through it. `selected` gives each bar's current space, as the Dock has it; without it, macOS's
    /// current spaces, which it announces only after switching.
    func draw(
        _ bars: [BarLayout], retraction: CGFloat, selected: [String?], slide: TimedSlide?, at frameTime: TimeInterval
    ) {
        let matching = MissionControlCaptionLook.isEnabled
        var labels: [MissionControlLabel] = []
        for (index, measured) in bars.enumerated() {
            let selectedTitle = index < selected.count ? selected[index] : nil
            // A bar growing into thumbnails is drawn at the thumbnails' places, each label moving there
            // from its name; one about to grow stays as it was until it starts.
            let growing = grow.flatMap { $0.screen == measured.screen ? $0 : nil }
            let held = pendingGrow.flatMap { $0.bar.screen == measured.screen ? $0.bar : nil }
            // A desktop coming or going: where the Dock will put the thumbnails, until it reports them.
            let predicted = reflow.flatMap { $0.screen == measured.screen ? $0.predicted : nil }
            let bar = growing?.to ?? held ?? predicted ?? measured
            // Placed as with the bar in; the overlay moves them all up by the retraction.
            let barTop = bar.screen.minY
            // Started half a frame early, as for `slide`.
            let sliding = shift.flatMap {
                $0.screen == bar.screen ? $0.slide.earlier(by: clock.frameDuration / 2) : nil
            }
            let offset = barTop - bar.frame.minY
            for caption in bar.captions {
                var centre = CGPoint(x: caption.centre.x, y: caption.centre.y + offset)
                // Covered by the zoom to another desktop, as the Dock's caption is.
                if let cover = zoomCover, zoom?.screen == bar.screen, cover.contains(centre) { continue }
                var dragged: TimedMove?
                if let drag, drag.screen == bar.screen {
                    if caption.spaceID == drag.spaceID {
                        // The dragged thumbnail shows no caption until it has settled where it was let go.
                        guard let settles = drag.settlesAt, frameTime + clock.frameDuration / 2 >= settles,
                              let slot = drag.gapCentre(in: bar)
                        else { continue }
                        // Once the Dock reports the drop, where it says.
                        if !drag.reported { centre.x = slot }
                    } else {
                        // The others move aside to make room.
                        if let slot = drag.place(of: caption.spaceID, in: bar), bar.buttons.indices.contains(slot) {
                            centre.x = bar.buttons[slot].frame.midX
                        }
                        // A move timed from the captions on screen is timed as they show: no lead.
                        dragged = drag.moves[caption.spaceID]?.earlier(by: drag.watched ? 0 : clock.frameDuration / 2)
                    }
                }
                let reflowing = reflow.flatMap { running in
                    running.screen == bar.screen ? running.from[caption.spaceID].map {
                        TimedMove(
                            timing: running.timing, reference: running.reference,
                            from: CGVector(dx: $0.x - caption.centre.x, dy: 0))
                        .earlier(by: clock.frameDuration / 2)
                    } : nil
                }
                let moving = dragged ?? reflowing ?? growing.flatMap { running in
                    running.from.captions.first { $0.covers == caption.covers }.map {
                        TimedMove(
                            timing: DockMotion.expand, reference: running.reference,
                            from: CGVector(dx: $0.centre.x - caption.centre.x, dy: $0.centre.y - caption.centre.y))
                        .earlier(by: clock.frameDuration / 2)
                    }
                }
                let found = matching ? look(for: caption, on: bar) : nil
                let variant = found?.look.variant(current: selectedTitle.map { $0 == caption.covers }
                    ?? currentSpaceIDs.contains(caption.spaceID))
                var label = Self.label(for: caption, centre: centre, screen: bar.screen, look: variant)
                label.barHeight = bar.frame.height
                label.shift = sliding
                label.grow = moving
                if let found, let variant {
                    // A look captured with the bar this height goes as high as the native caption was found,
                    // whichever thumbnail it was under; one from the bar at another height can only follow
                    // the Dock's caption.
                    label.lookOrigin = CGPoint(
                        x: centre.x + variant.frame.minX,
                        y: found.sameHeight ? barTop + variant.top : centre.y + variant.frame.minY)
                }
                if let dropped = droppedSpace, dropped.spaceID == caption.spaceID {
                    traceDropped(caption, label: label, look: found, at: frameTime, since: dropped.time)
                }
                labels.append(label)
            }
        }
        overlay.render(labels, retraction: retraction, slide: slide, redrawing: drag != nil)
        if MissionControlCaptionLook.isDebugging { trace(bars.first, labels: labels, retraction: retraction) }
        traceDrag(bars, labels: labels, at: frameTime)
    }

    static func label(
        for caption: Caption, centre: CGPoint, screen: CGRect, look: NativeCaptionLook.Variant?
    ) -> MissionControlLabel {
        var label = MissionControlLabel(
            name: caption.name, covers: caption.covers, maxWidth: caption.maxWidth,
            colorHex: caption.colorHex, centre: centre, screen: screen, look: look)
        label.key = caption.spaceID
        return label
    }
}
