//
//  MissionControlLabels+Drawing.swift
//  Spaceman
//
//  Turns the measured bars into the labels the overlay draws, each frame.
//

import AppKit

extension MissionControlLabels {

    /// How long into the grow from the names macOS's own captions under the thumbnails not hovered take to
    /// fade halfway out, on a magnifying bar: filmed on macOS 26.7 with 16 desktops. Labels never fade:
    /// theirs go at that halfway point, as a hovered label moves on at the middle of a gap.
    private static let growCaptionFade: TimeInterval = 0.06

    /// Draws every bar's labels with the bar `retraction` of the way off its screen, or moving with
    /// `slide`. The labels stay opaque all the way: a fading label would show the native caption
    /// through it. `selected` gives each bar's current space, as the Dock has it; without it, macOS's
    /// current spaces, which it announces only after switching.
    func draw(
        _ bars: [BarLayout], retraction: CGFloat, selected: [Int?], slide: TimedSlide?, at frameTime: TimeInterval
    ) {
        let matching = labelStyle == .nativeLook
        var labels: [MissionControlLabel] = []
        var shownByBar: [(bar: BarLayout, shown: ShownLabels)] = []
        for (index, measured) in bars.enumerated() {
            let selectedPlace = index < selected.count ? selected[index] : nil
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
            let shown = shownLabels(on: bar)
            shownByBar.append((bar, shown))
            let ridingGrow = growing.map { frameTime < $0.reference + DockMotion.expand.delay + Self.growCaptionFade }
            for caption in bar.captions {
                // A label macOS draws no caption for goes; one riding the grow from the names goes once the
                // caption it covers has half faded.
                guard shown.shows(caption) || ridingGrow == true else { continue }
                var centre = CGPoint(x: caption.centre.x, y: caption.centre.y + offset)
                // Covered by the zoom to another desktop, as the Dock's caption is.
                if let cover = zoomCover, zoom?.screen == bar.screen, cover.contains(centre) { continue }
                let found = matching ? captionLooks.look(for: caption, on: bar) : nil
                guard found != nil || !lookMayArrive(for: caption, on: bar) else { continue }
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
                let running = reflow.flatMap { $0.screen == bar.screen ? $0 : nil }
                if running?.holds(caption) == true { continue }
                let reflowing = running?.move(of: caption)?.earlier(by: clock.frameDuration / 2)
                let moving = dragged ?? reflowing ?? growing.flatMap { running in
                    running.from.captions.first { $0.spaceID == caption.spaceID }.map {
                        TimedMove(
                            timing: DockMotion.expand, reference: running.reference,
                            from: CGVector(dx: $0.centre.x - caption.centre.x, dy: $0.centre.y - caption.centre.y))
                        .earlier(by: clock.frameDuration / 2)
                    }
                }
                let variant = found?.look.variant(current: Self.isCurrent(
                    caption, selected: selectedPlace, on: measured, currentSpaceIDs: currentSpaceIDs))
                var label = Self.label(for: caption, centre: centre, screen: bar.screen, look: variant)
                label.barHeight = bar.frame.height
                label.shift = sliding
                label.grow = moving
                if let variant {
                    // As high as the native caption was found with the bar this height, whichever thumbnail
                    // it was under.
                    label.lookOrigin = CGPoint(x: centre.x + variant.frame.minX, y: barTop + variant.top)
                }
                if let dropped = droppedSpace, dropped.spaceID == caption.spaceID {
                    traceDropped(caption, label: label, look: found, at: frameTime, since: dropped.time)
                }
                labels.append(label)
            }
        }
        overlay.render(labels, retraction: retraction, slide: slide, redrawing: drag != nil)
        recordDrawn(at: frameTime)
        recordShown(shownByBar, at: frameTime)
        if MissionControlCaptionLook.isDebugging { trace(bars.first, labels: labels, retraction: retraction) }
        traceDrag(bars, labels: labels, at: frameTime)
    }

    /// Which of `bar`'s labels are drawn: on a bar of thumbnails that magnifies, only the hovered one's.
    func shownLabels(on bar: BarLayout) -> ShownLabels {
        ShownLabels.on(bar, magnifies: magnification.magnifies(bar), pointer: pointer?.point)
    }

    /// Whether `caption`'s space is the current one, which has its pill: the space of the thumbnail the
    /// Dock has selected on `measured`, the bar as it reported it, or without a selection macOS's current
    /// spaces. Told by space, as a bar drawn where a desktop is being removed has its places renumbered.
    /// A selection whose space isn't known has no pill.
    static func isCurrent(
        _ caption: Caption, selected: Int?, on measured: BarLayout, currentSpaceIDs: Set<String>
    ) -> Bool {
        guard let selected else { return currentSpaceIDs.contains(caption.spaceID) }
        return measured.spaceIDs.indices.contains(selected) && measured.spaceIDs[selected] == caption.spaceID
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
