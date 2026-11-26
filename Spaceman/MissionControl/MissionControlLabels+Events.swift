//
//  MissionControlLabels+Events.swift
//  Spaceman
//
//  The window server's Mission Control events, clicks on the Spaces Bar, and desktops added
//  or removed while it is open.
//

import AppKit

extension MissionControlLabels {

    /// The window server posts each event twice, this close together.
    private static let repeatedEventWindow: TimeInterval = 0.1

    /// How far from a thumbnail's top-left corner a click counts as on its close button.
    private static let closeCornerReach: CGFloat = 14
    /// How long after the window server's event a change of desktops is still timed from it.
    private static let spaceChangeWindow: TimeInterval = 1.5
    /// How long after a click on the add or close button the window server's event belongs to it.
    private static let changeClickWindow: TimeInterval = 0.3

    /// Listens for Mission Control starting, once per launch.
    func observeWindowServer() {
        guard !registeredWindowServerEvents else { return }
        registeredWindowServerEvents = true
        seesMissionControlBegin = WindowServerEvents.observe(
            [WindowServerEvents.missionControlBegan, WindowServerEvents.missionControlEnded]
        ) { [weak self] type, time, payload in
            self?.windowServerEvent(type, at: time, payload: payload)
        }
    }

    /// A click on a thumbnail closes Mission Control into that desktop, the bar sliding up as it goes,
    /// which the Dock reports only some way in: slide the labels up with it from the click. A click on
    /// the add button, or on a thumbnail's close button, waits for the window server to confirm it.
    func handleClick(at point: CGPoint) {
        let time = ProcessInfo.processInfo.systemUptime
        let change = restingLayouts.lazy.compactMap { Self.desktopChange(bar: $0, at: point) }.first
        record(String(format: "click at %.0f,%.0f", point.x, point.y) + (change.map { " (\($0))" } ?? ""), at: time)
        guard isTracking, retraction <= 0, swipe.state == .idle, slide == nil else { return }
        if let change {
            pendingChange = (change, time)
            return
        }
        guard let bar = restingLayouts.first(where: { bar in bar.buttons.contains { $0.frame.contains(point) } }),
              let place = bar.buttons.firstIndex(where: { $0.frame.contains(point) })
        else { return }
        let button = bar.buttons[place]
        let reading = reader.latest(waitingUpTo: 0)
        let current = reading.layouts.indices.contains { index in
            reading.layouts[index].screen == bar.screen && index < reading.selected.count
                && reading.selected[index] == place
        }
        noteMotion()
        if current {
            // This desktop: Mission Control closes, the bar sliding up.
            slide = TimedSlide(timing: DockMotion.choose, reference: time, from: 0, to: 1)
            record("chose this desktop", at: time)
            return
        }
        // Another desktop zooms out of its thumbnail over the bar, which stays where it is, its captions
        // showing until the zoom covers them: so do the labels, kept to this desktop since they came in.
        zoom = (bar.screen, button.frame, time)
        record("chose \(button.title)", at: time)
    }

    /// What a click at `point` on `bar` does to its desktops, if anything: the add button in the
    /// screen's corner, or the close button the Dock shows at a hovered thumbnail's top-left corner.
    private static func desktopChange(bar: BarLayout, at point: CGPoint) -> DesktopChange? {
        if bar.addButton?.contains(point) == true { return .add(screen: bar.screen) }
        guard bar.frame.height > expandedBarHeight else { return nil }
        return bar.buttons.firstIndex {
            abs(point.x - $0.frame.minX) <= closeCornerReach && abs(point.y - $0.frame.minY) <= closeCornerReach
        }.map { .remove(screen: bar.screen, index: $0) }
    }

    /// A desktop added or removed: the Dock reports the thumbnails' new places some way into moving them
    /// there, so replay the move from the window server's event, or from now without one.
    func noticeDesktopsChange(from old: [BarLayout], to new: [BarLayout], at time: TimeInterval) -> Bool {
        guard let after = new.first(where: { bar in
                  old.contains { $0.screen == bar.screen && $0.buttons.count != bar.buttons.count }
              }),
              let before = old.first(where: { $0.screen == after.screen }),
              before.frame.height == after.frame.height
        else { return false }
        if var running = reflow, running.screen == after.screen, running.count == after.buttons.count {
            // Replaying it already, from the click: carry on to where the Dock has put the thumbnails.
            running.predicted = nil
            reflow = running
            record("desktops reported", at: time)
            return true
        }
        let added = after.buttons.count > before.buttons.count
        let timing = added ? DockMotion.add : DockMotion.remove
        let began = spaceChangeBeganAt.flatMap { time - $0 < Self.spaceChangeWindow ? $0 : nil }
        spaceChangeBeganAt = nil
        reflow = Reflow(screen: after.screen, timing: timing, reference: began ?? time - timing.delay,
                        from: Self.centres(of: before.atRest()), spacesBefore: before.spaceIDs,
                        count: after.buttons.count)
        shift = nil
        record(added ? "desktop added" : "desktop removed", at: began ?? time)
        return true
    }

    /// A click to add or remove a desktop, confirmed by the window server at `time`: the Dock starts
    /// moving the thumbnails on its timing, and reports where it puts them only some way in, so move
    /// the labels towards where it will put them.
    private func startReflow(_ change: DesktopChange, at time: TimeInterval) {
        guard let before = restingLayouts.first(where: { $0.screen == change.screen }), !before.buttons.isEmpty
        else { return }
        let count: Int
        let removed: Int?
        switch change {
        case .add:
            count = before.buttons.count + 1
            removed = nil
        case .remove(_, let index):
            guard before.buttons.indices.contains(index) else { return }
            count = before.buttons.count - 1
            removed = index
        }
        let known = expandedLayoutsByCount["\(before.displayID)|\(count)"]
        let centres = known.map { $0.buttons.map(\.frame.midX) } ?? before.buttons.first.map { first in
            Self.predictedCentres(
                count: count, shown: before.buttons.count, screenMinX: before.screen.minX,
                screenWidth: before.screen.width, width: first.frame.width,
                spacing: before.buttons.count > 1 ? before.buttons[1].frame.midX - first.frame.midX : first.frame.width)
        } ?? []
        guard centres.count == count,
              let predicted = Self.predictedLayout(before, centres: centres, removing: removed)
        else { return }
        let timing: DockMotion.Timing
        if case .add = change { timing = DockMotion.add } else { timing = DockMotion.remove }
        reflow = Reflow(screen: before.screen, timing: timing, reference: time, from: Self.centres(of: before),
                        spacesBefore: before.spaceIDs, count: count, predicted: predicted)
        shift = nil
        record("\(change) from the click" + (known == nil ? ", places worked out" : ", places seen before"), at: time)
    }

    /// `before`'s labels at the thumbnails' places `centres` once the one at `removed`, if any, is gone,
    /// or nil when a label's place falls outside them, as when a measurement already left it out.
    static func predictedLayout(_ before: BarLayout, centres: [CGFloat], removing removed: Int?) -> BarLayout? {
        var predicted = before
        // Which space each thumbnail shows is known only once the Dock reports them.
        predicted.spaceIDs = []
        var captions: [Caption] = []
        for caption in before.captions where caption.index != removed {
            let place = removed.map { caption.index > $0 ? caption.index - 1 : caption.index } ?? caption.index
            guard centres.indices.contains(place) else { return nil }
            let spacing = centres.count > 1 ? abs(centres[1] - centres[0]) : caption.maxWidth + labelGap
            var moved = caption
            moved.centre.x = centres[place]
            moved.maxWidth = spacing - labelGap
            moved.index = place
            captions.append(moved)
        }
        predicted.captions = captions
        return predicted
    }

    private static func centres(of bar: BarLayout) -> [String: CGPoint] {
        Dictionary(bar.captions.map { ($0.spaceID, $0.centre) }) { first, _ in first }
    }

    /// Where the Dock centres `count` thumbnails on a screen, from a strip of `shown` thumbnails
    /// `width` wide and `spacing` apart. Filling the screen, they keep the gaps between them in
    /// proportion and the same margin at each end, narrowing as desktops are added; with room to spare
    /// they keep their size. Measured on macOS 26.7 with 14 and 15 desktops on a 2560-point screen.
    static func predictedCentres(
        count: Int, shown: Int, screenMinX: CGFloat, screenWidth: CGFloat, width: CGFloat, spacing: CGFloat
    ) -> [CGFloat] {
        guard count > 0, shown > 0, width > 0 else { return [] }
        let gapRatio = max(spacing - width, 0) / width
        // The margin at each end of the strip it came from, if it filled the screen.
        let margin = (screenWidth - (CGFloat(shown - 1) * spacing + width)) / 2
        let fills = margin <= fullStripMargin + fullStripSlack
        let fitted = (screenWidth - 2 * min(margin, fullStripMargin + fullStripSlack))
            / (CGFloat(count) + CGFloat(count - 1) * gapRatio)
        let newWidth = fills ? fitted : min(width, fitted)
        let newSpacing = newWidth * (1 + gapRatio)
        let first = screenMinX + screenWidth / 2 - CGFloat(count - 1) * newSpacing / 2
        return (0..<count).map { first + CGFloat($0) * newSpacing }
    }

    /// The margin at each end of a strip of thumbnails that fills the screen, as measured.
    private static let fullStripMargin: CGFloat = 77.5
    private static let fullStripSlack: CGFloat = 8

    private func windowServerEvent(_ type: Int32, at time: TimeInterval, payload: [UInt8]) {
        record("window server \(type) " + payload.map { String(format: "%02x", $0) }.joined(), at: time)
        if type == WindowServerEvents.missionControlBegan { missionControlBegan(at: time) }
        if type == WindowServerEvents.missionControlEnded {
            missionControlEndedAt = time
            if isTracking, drag != nil {
                // The dragged thumbnail has settled in its new place.
                drag = nil
                stopWatching()
                reader.remeasureSoon()
                record("drag over", at: time)
                // Have the space names keep their new places: a later launch or wake matches names to
                // spaces by place, and would swap them by the old ones.
                NotificationCenter.default.post(name: autoRefreshTriggeredName, object: nil)
            }
        }
    }

    /// The window server says Mission Control is starting: 12-19ms after the key that opens it, while
    /// the Dock won't answer Accessibility requests until the bar has landed. Slide the labels in on
    /// the Dock's timing, from the last session's layout.
    private func missionControlBegan(at time: TimeInterval) {
        // It comes twice for each start.
        if let last = missionControlBeganAt, time - last < Self.repeatedEventWindow { return }
        missionControlBeganAt = time
        guard isEnabled, Self.spacesBarIsInDock else { return }
        // A swipe opening Mission Control confirms itself with this time (see `dockTookSwipe`).
        if swipe.isGestureActive || swipe.state != .idle { return }
        if isTracking, let timed = slide, timed.to > timed.from,
           let ended = missionControlEndedAt, ended >= timed.reference {
            // The Dock has finished closing, though the labels are still on their way out: a fresh open.
            endTracking()
        }
        if isTracking {
            // Asked back while closing: the Dock turns the bar around from where it is.
            if let timed = slide, timed.to > timed.from {
                slide = TimedSlide(timing: DockMotion.reverse, reference: time, from: timed.retraction(at: time), to: 0)
                record("reverse", at: time)
            } else if slide == nil {
                // Open already: a desktop is being added or removed, or a thumbnail dragged.
                spaceChangeBeganAt = time
                if let pending = pendingChange, time - pending.time < Self.changeClickWindow {
                    startReflow(pending.change, at: time)
                } else if let pressed = swipe.pressedAt {
                    startDrag(from: pressed, at: time)
                }
                pendingChange = nil
            }
            return
        }
        // Without an earlier session's layout there is nothing to slide in: wait for the Dock.
        if !restingLayouts.isEmpty {
            slide = TimedSlide(timing: DockMotion.open, reference: time, from: 1, to: 0)
            record("open", at: time)
        }
        beginTracking()
        if !isTracking { slide = nil }
    }
}
