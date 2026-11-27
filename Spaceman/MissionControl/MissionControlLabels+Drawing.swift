//
//  MissionControlLabels+Drawing.swift
//  Spaceman
//
//  Turns the measured bars into the labels the overlay draws, each frame.
//

import AppKit

extension MissionControlLabels {

    /// How long after the pointer enters the bar of names macOS's captions under a magnifying bar's thumbnails
    /// not hovered are gone. They ride the grow down with the hovered one's, fading, and vanish once landed: filmed
    /// on macOS 26.7 with 16 desktops, the last frame showing them came 0.204-0.217s after, in three expansions,
    /// and the first without them 0.221-0.234s after. Labels never fade: every one stays until a frame past that,
    /// the pointer's entry being noticed up to a frame late.
    static let growCaptionsGone: TimeInterval = 0.25

    /// How far through the grow from the names a magnifying bar's labels are.
    enum GrowPhase: Equatable {
        /// Riding down with macOS's captions, in the looks of those on the names.
        case riding
        /// Landed under the thumbnails, every one, while macOS's captions under those not hovered are there.
        case landed
        /// Over: only those macOS captions are drawn.
        case over
    }

    /// The grow's phase in the frame reaching the screen at `time`, the pointer having entered the bar at `reference`.
    static func growPhase(at time: TimeInterval, reference: TimeInterval) -> GrowPhase {
        if time < DockMotion.growCaptions.end(from: reference) { return .riding }
        return time < reference + growCaptionsGone ? .landed : .over
    }

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
            noteHover(on: bar, at: frameTime)
            let shown = shownLabels(on: bar, at: frameTime)
            shownByBar.append((bar, shown))
            let phase = growing.map { Self.growPhase(at: frameTime, reference: $0.reference) }
            let magnifies = matching && magnification.magnifies(bar)
            let drawing = magnifies ? stripDrawing(for: bar, shown: shown, at: frameTime) : nil
            for caption in bar.captions {
                // A label macOS draws no caption for goes; in the grow from the names, every one stays until
                // macOS's captions under the thumbnails not hovered have gone.
                guard shown.shows(caption) || (phase ?? .over) != .over else { continue }
                var centre = CGPoint(x: caption.centre.x, y: caption.centre.y + offset)
                // Covered by the zoom to another desktop, as the Dock's caption is.
                if let cover = zoomCover, zoom?.screen == bar.screen, cover.contains(centre) { continue }
                let leaving = phase == .riding ? growing.flatMap { running in
                    running.from.captions.first { $0.spaceID == caption.spaceID }.map { (running.from, $0) }
                } : nil
                let source = matching ? Self.lookSource(
                    for: caption, on: bar, strip: drawing, leaving: leaving, looks: &captionLooks)
                    : .fallback(nil)
                if case .awaited = source { continue }
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
                let current = Self.isCurrent(
                    caption, selected: selectedPlace, on: measured, currentSpaceIDs: currentSpaceIDs)
                let plain = Self.label(for: caption, centre: centre, screen: bar.screen, look: nil)
                guard var label = dressed(plain, from: source, current: current, style: drawing?.style)
                else { continue }
                label.barHeight = bar.frame.height
                label.shift = sliding
                label.grow = dragged ?? reflowing ?? growing.flatMap { running in
                    growMove(of: label, for: caption, from: source, in: running, magnifies: magnifies)
                }
                if let dropped = droppedSpace, dropped.spaceID == caption.spaceID {
                    traceDropped(caption, label: label, look: source.captured, at: frameTime, since: dropped.time)
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

    /// `label`'s move with the bar of names growing into thumbnails as `running` has it, `caption` its caption
    /// there: from where it sat on the names to where it is placed, timed as macOS's captions are on a bar that
    /// `magnifies`, else as the thumbnails are. Started half a frame early, as for `slide`.
    private func growMove(
        of label: MissionControlLabel, for caption: Caption, from source: LookSource,
        in running: (screen: CGRect, reference: TimeInterval, from: BarLayout, to: BarLayout), magnifies: Bool
    ) -> TimedMove? {
        let from: CGVector
        if case .riding(_, let leaving, _) = source, let look = label.look, let end = label.lookOrigin {
            let start = Self.rideStart(of: look, leaving: leaving, barTop: label.screen.minY)
            from = CGVector(dx: start.x - end.x, dy: start.y - end.y)
        } else {
            guard let leaving = running.from.captions.first(where: { $0.spaceID == caption.spaceID }) else {
                return nil
            }
            from = CGVector(dx: leaving.centre.x - caption.centre.x, dy: leaving.centre.y - caption.centre.y)
        }
        return TimedMove(timing: magnifies ? DockMotion.growCaptions : DockMotion.expand, reference: running.reference,
                         from: from).earlier(by: clock.frameDuration / 2)
    }

    /// Where a label riding the grow in `look`, the look of the caption at `leaving` on the names, starts: where
    /// that caption was.
    static func rideStart(of look: NativeCaptionLook.Variant, leaving: CGPoint, barTop: CGFloat) -> CGPoint {
        CGPoint(x: leaving.x + look.frame.minX, y: barTop + look.top)
    }

    /// Where a label riding the grow in `look`, the look of the caption at `leaving` on the names, lands over the
    /// caption the Dock puts at `centre`: its name where a strip draws it, `landing` (its ink's middle across and
    /// its baseline below the bar's top), when there is one; else as far from where it started as the Dock's
    /// captions are apart.
    static func rideEnd(
        of look: NativeCaptionLook.Variant, leaving: CGPoint, centre: CGPoint, landing: CGPoint?, barTop: CGFloat
    ) -> CGPoint {
        guard let landing else {
            return CGPoint(x: centre.x + look.frame.minX, y: barTop + look.top + centre.y - leaving.y)
        }
        return CGPoint(x: landing.x - look.frame.width / 2, y: barTop + landing.y - look.baseline)
    }

    /// Where a label's look comes from in the native look.
    enum LookSource {
        /// The caption strip of the magnifying bar it is on.
        case strip(CaptionStrip)
        /// A capture of its own caption, or one of its name elsewhere.
        case captured(FoundLook)
        /// A capture of the caption it rides the grow from, on the names, at `leaving`: landing where `strip`
        /// draws the label, when there is one.
        case riding(FoundLook, leaving: CGPoint, onto: CaptionStrip?)
        /// None yet: macOS's own caption shows until one arrives.
        case awaited
        /// None will arrive in time: drawn plainly, so the name still shows; on a magnifying bar on a plate of the
        /// bar's colour where that is known, else as a box in its space's colour.
        case fallback(StripFallback?)

        var captured: FoundLook? {
            switch self {
            case .captured(let found), .riding(let found, _, _): return found
            default: return nil
            }
        }
    }

    /// Where `caption`'s look comes from on `bar`, in the native look. On a magnifying bar, drawn as `strip` has it,
    /// whatever thumbnail it is under, with no capture of the caption itself, unless it rides the grow from the
    /// names, `leaving` that bar and its caption there, whose capture it takes while there is one. Elsewhere, a
    /// capture of the caption.
    static func lookSource(
        for caption: Caption, on bar: BarLayout, strip drawing: StripDrawing?,
        leaving: (bar: BarLayout, caption: Caption)?, looks: inout CaptionLooks
    ) -> LookSource {
        if let drawing {
            if let leaving, let found = looks.look(for: leaving.caption, on: leaving.bar) {
                return .riding(found, leaving: leaving.caption.centre, onto: drawing.strip)
            }
            if let strip = drawing.strip { return .strip(strip) }
            return drawing.awaited ? .awaited : .fallback(drawing.fallback)
        }
        if let found = looks.look(for: caption, on: bar) { return .captured(found) }
        return looks.lookMayArrive(for: caption, on: bar) ? .awaited : .fallback(nil)
    }

    /// `label` with its look from `source`, as the current space's or not, placed as high as the native caption sits
    /// in a bar this tall; a strip's drawn in `style`. Nil when a strip's label can't be drawn: then macOS's caption
    /// shows rather than the fallback.
    private func dressed(
        _ label: MissionControlLabel, from source: LookSource, current: Bool, style: CaptionStrip.Style?
    ) -> MissionControlLabel? {
        var dressed = label
        let barTop = label.screen.minY
        switch source {
        case .strip(let strip):
            guard let style, let drawn = stripFace(for: label, strip: strip, style: style, current: current)
            else { return nil }
            dressed.strip = drawn.face
            dressed.lookOrigin = CGPoint(x: drawn.left, y: barTop + strip.top)
        case .captured(let found):
            dressed.wear(found.look, current: current, barTop: barTop)
        case .riding(let found, let leaving, let strip):
            dressed.look = found.look.variant(current: current)
            let landing = strip.flatMap { strip in
                style.map { strip.landing(underThumbnailAt: label.centre.x,
                                          inkOffset: stripNames.ink(of: label.covers, style: $0.text).offset) }
            }
            dressed.lookOrigin = dressed.look.map {
                Self.rideEnd(of: $0, leaving: leaving, centre: label.centre, landing: landing, barTop: barTop)
            }
        case .fallback(let fallback):
            guard let fallback, let style else { break }
            let placed = fallbackPlate(for: label, fallback: fallback, style: style)
            dressed.plate = placed.plate
            dressed.lookOrigin = placed.origin
        case .awaited:
            break
        }
        return dressed
    }

    /// Which of `bar`'s labels are drawn in the frame reaching the screen at `time`: on a bar of thumbnails that
    /// magnifies, the hovered one's, with those beside a gap the pointer is about to cross and the one it just left.
    func shownLabels(on bar: BarLayout, at time: TimeInterval) -> ShownLabels {
        let kept = hoverTrails[BarMagnification.key(of: bar)]?.kept(at: time, frameDuration: clock.frameDuration)
        return ShownLabels.on(
            bar, magnifies: magnification.magnifies(bar), pointer: pointer?.point,
            reach: ShownLabels.reach(speed: pointerPace.speed, frameDuration: clock.frameDuration), keeping: kept)
    }

    /// Notes the thumbnail hovered on `bar`, if any, in the frame reaching the screen at `time`.
    private func noteHover(on bar: BarLayout, at time: TimeInterval) {
        let hovered = ShownLabels.on(bar, magnifies: magnification.magnifies(bar), pointer: pointer?.point).hovered
        hoverTrails[BarMagnification.key(of: bar), default: HoverTrail()].note(hovered, at: time)
    }

    /// Whether `caption`'s space is the current one, which has its pill: the space of the thumbnail the
    /// Dock has selected on `measured`, the bar as it reported it, or without a selection macOS's current
    /// spaces. Told by space, as a bar drawn where a desktop is being removed has its places renumbered.
    /// A selection whose space isn't known has no pill.
    static func isCurrent(
        _ caption: Caption, selected: Int?, on measured: BarLayout, currentSpaceIDs: Set<String>
    ) -> Bool {
        isCurrent(spaceID: caption.spaceID, selected: selected, on: measured, currentSpaceIDs: currentSpaceIDs)
    }

    static func isCurrent(
        spaceID: String, selected: Int?, on measured: BarLayout, currentSpaceIDs: Set<String>
    ) -> Bool {
        guard let selected else { return currentSpaceIDs.contains(spaceID) }
        return measured.spaceIDs.indices.contains(selected) && measured.spaceIDs[selected] == spaceID
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

private extension MissionControlLabel {

    /// Takes `look`, as the current space's or not, placed under whichever thumbnail the native caption was found
    /// under, as far below `barTop` as it was found.
    mutating func wear(_ look: NativeCaptionLook, current: Bool, barTop: CGFloat) {
        self.look = look.variant(current: current)
        lookOrigin = self.look.map { CGPoint(x: centre.x + $0.frame.minX, y: barTop + $0.top) }
    }
}
