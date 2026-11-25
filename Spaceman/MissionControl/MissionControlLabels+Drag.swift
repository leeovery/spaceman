//
//  MissionControlLabels+Drag.swift
//  Spaceman
//
//  A thumbnail dragged along the Spaces Bar: the others moving aside for it, told from
//  Mission Control's own captions, and where it lands once let go.
//

import AppKit

extension MissionControlLabels {

    /// A thumbnail dragged to another place and let go: the Dock reorders the desktops at once, and
    /// says so in its preferences, so measure the bars again now rather than at the next due time.
    func handleDrop(at point: CGPoint) {
        guard isTracking else { return }
        record(String(format: "drop at %.0f,%.0f", point.x, point.y))
        let now = ProcessInfo.processInfo.systemUptime
        stopWatching()
        drag?.dropped = true
        drag?.droppedAt = now
        // Shown just before the Dock's caption comes back, 0.26-0.29s after the drop: watching for it
        // would show it a frame or two after.
        drag?.settlesAt = now + Self.dropSettle
        droppedSpace = drag?.spaceID.map { ($0, now) }
        reader.remeasureSoon()
    }

    /// The window server announces a thumbnail picked up to drag as it announces Mission Control
    /// starting. The dragged thumbnail shows no caption, and the others make room for it.
    func startDrag(from point: CGPoint, at time: TimeInterval) {
        // Event locations are in Accessibility's coordinates already.
        guard let bar = restingLayouts.first(where: { bar in bar.buttons.contains { $0.frame.contains(point) } }),
              let origin = bar.buttons.firstIndex(where: { $0.frame.contains(point) })
        else { return }
        // The Dock reckons the dragged thumbnail from where the pointer is as the drag starts, a few points
        // on from the press.
        let pointer = Self.axPoint(NSEvent.mouseLocation)
        let started = ThumbnailDrag(
            bar: bar, origin: origin, grabOffset: (pointer.x - bar.buttons[origin].frame.midX) * Self.dragHold,
            at: time)
        drag = started
        startWatching(bar)
        record(String(format: "dragging %@, space %@, grabbed %.0f from its middle", bar.buttons[origin].title,
                      started.spaceID ?? "none", started.grabOffset), at: time)
    }

    /// The dragged thumbnail reaching another's place: the Dock moves that one, and any between, one
    /// place along to make room.
    func dragMoved(to point: CGPoint, at time: TimeInterval) {
        guard isTracking, var running = drag, !running.dropped, !(running.watched && watcherIsLive),
              let bar = restingLayouts.first(where: { $0.screen == running.screen }), bar.buttons.count > 1
        else { return }
        // Until its captions can be watched, the Dock is taken to go by where it reckons the dragged
        // thumbnail's middle, near where it was grabbed: a thumbnail moves aside once that crosses a point
        // just right of its middle.
        let gap = Self.dragGap(
            from: running.gap, centres: bar.buttons.map(\.frame.midX), middleX: point.x - running.grabOffset)
        guard gap != running.gap else { return }
        moveGap(of: &running, to: gap, in: bar, at: time)
        drag = running
        record("room made at \(gap + 1)", at: time)
    }

    /// Moves the dragged thumbnail's place to `gap`, starting the labels it passes moving aside.
    private func moveGap(of running: inout ThumbnailDrag, to gap: Int, in bar: BarLayout, at time: TimeInterval) {
        let centres = bar.buttons.map(\.frame.midX)
        let before = running
        running.gap = gap
        for index in bar.buttons.indices where index != running.origin {
            if Self.place(of: index, origin: running.origin, gap: before.gap)
                != Self.place(of: index, origin: running.origin, gap: gap) {
                running.movingUntil[index] = DockMotion.makeRoom.end(from: time)
            }
        }
        for caption in bar.captions where caption.spaceID != running.spaceID {
            guard let from = before.place(of: caption.spaceID, in: bar),
                  let to = running.place(of: caption.spaceID, in: bar), from != to,
                  centres.indices.contains(from), centres.indices.contains(to)
            else { continue }
            let still = before.moves[caption.spaceID]?.offset(at: time).dx ?? 0
            running.moves[caption.spaceID] = TimedMove(
                timing: DockMotion.makeRoom, reference: time,
                from: CGVector(dx: centres[from] + still - centres[to], dy: 0))
        }
    }

    /// Once the Dock reports the bars after a drop, puts the labels where it put the thumbnails, if they
    /// were reckoned elsewhere: dropped where it was picked up from, the Dock keeps the order.
    func settleDrop(_ layouts: [BarLayout], answered: TimeInterval) {
        guard var running = drag, running.dropped, !running.reported, let dropped = running.droppedAt,
              let bar = layouts.first(where: { $0.screen == running.screen })
        else { return }
        // A reading taken as the thumbnail was let go can predate the Dock's reordering: ask again.
        guard answered > dropped + Self.dropReorderTime else {
            reader.remeasureSoon()
            return
        }
        running.reported = true
        if bar.captions.map(\.spaceID) == running.order, running.gap != running.origin {
            record("drop put back at \(running.origin + 1), not \(running.gap + 1)", at: answered)
            moveGap(of: &running, to: running.origin, in: bar, at: ProcessInfo.processInfo.systemUptime)
        }
        drag = running
    }

    private var watcherIsLive: Bool {
        captionWatcher?.isLive ?? false
    }

    /// Watches Mission Control's own captions across `bar`'s screen while a thumbnail is dragged over it.
    /// Only for the native look: in the spaces' colours nothing captures the screen.
    private func startWatching(_ bar: BarLayout) {
        guard labelStyle == .nativeLook, let captionY = bar.captions.first?.centre.y else { return }
        let watcher: MissionControlCaptionWatcher
        if let existing = captionWatcher {
            watcher = existing
        } else {
            watcher = MissionControlCaptionWatcher()
            watcher.onChange = { [weak self] in self?.captionsChanged() }
            watcher.onNote = { [weak self] note in self?.record(note) }
            captionWatcher = watcher
        }
        lastWatchedFrame = 0
        watcher.start(
            displayID: bar.displayID, screen: bar.screen,
            band: CGRect(x: bar.screen.minX, y: captionY - Self.captionBand / 2, width: bar.screen.width,
                         height: Self.captionBand))
    }

    func stopWatching() {
        captionWatcher?.stop()
    }

    /// Takes in the newest frame of Mission Control's captions, during a drag, waiting briefly for the
    /// one now on screen.
    @discardableResult
    func watchCaptions(frameTime: TimeInterval, wait: TimeInterval = watchWait) -> Bool {
        guard let running = drag, !running.dropped,
              let watcher = captionWatcher,
              let frame = watcher.frame(
                after: lastWatchedFrame, expecting: frameTime - clock.frameDuration * 1.5, waitingUpTo: wait)
        else { return false }
        lastWatchedFrame = frame.shown
        let gap = running.gap
        captionsSeen(frame.middles, shownAt: frame.shown)
        return drag?.gap != gap
    }

    /// A frame of the captions showing a change has arrived, usually after this display frame's labels
    /// were drawn: if it shows the Dock making room, draw them again now, so they move a frame sooner.
    private func captionsChanged() {
        guard isTracking, drag != nil, zoom == nil, slide == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frameTime = max(clock.targetTime ?? now, now)
        guard watchCaptions(frameTime: frameTime, wait: 0) else { return }
        record(String(format: "redrawn for the captions, %.1fms after the frame was shown",
                      (now - lastWatchedFrame) * 1000), at: now)
        place(at: retraction, slide: nil, reading: reader.latest(waitingUpTo: 0), frameTime: frameTime)
    }

    /// A frame of Mission Control's own captions, shown at `shown`, during a drag: once a thumbnail's
    /// caption leaves its place, the Dock has started moving it aside, so the labels go too, from then.
    private func captionsSeen(_ middles: [CGFloat], shownAt shown: TimeInterval) {
        guard isTracking, var running = drag, !running.dropped, shift == nil,
              shown > running.startedAt + Self.watchAfter,
              let bar = restingLayouts.first(where: { $0.screen == running.screen }),
              let slots = Self.slotCentres(bar.buttons.map(\.frame.midX))
        else { return }
        let moving = Set(running.movingUntil.filter { $0.value > shown }.keys)
        guard let seen = Self.watchedGap(
            middles: middles, slots: slots, origin: running.origin, gap: running.gap, moving: moving)
        else { return }
        if !running.watched {
            running.watched = true
            record("captions watched", at: shown)
        }
        if seen.gap != running.gap {
            // Started as long before the frame as the captions took to go as far as they have. A caption
            // seen only just off its place has barely begun: its move gets going a little after.
            let spacing = abs(slots[1] - slots[0])
            let elapsed = seen.gone.map { gone in
                gone * spacing < Self.justStarted ? -Self.startAfterNudge : DockMotion.makeRoom.time(toReach: gone)
            } ?? clock.frameDuration / 2
            moveGap(of: &running, to: seen.gap, in: bar, at: shown - elapsed)
            record(String(format: "captions show room made at %d, %.0fms ago", seen.gap + 1, elapsed * 1000),
                   at: shown)
        }
        drag = running
    }

    /// What a frame of Mission Control's own captions, at `middles` across the screen, says of a
    /// dragged thumbnail's place, last known to be `gap`, it having been picked up from `origin`, over
    /// places with middles at `slots`. A thumbnail at rest shows its caption at its place; one whose
    /// caption has left it has started moving aside for the dragged one, as have any between. `moving`
    /// holds the thumbnails already moving, by their places as picked up. Nil when too few captions
    /// show where they should to tell, as while the bar slides; otherwise the place, and how far, as a
    /// share of the spacing, the caption nearest moving there has gone, if it shows.
    static func watchedGap(
        middles: [CGFloat], slots: [CGFloat], origin: Int, gap: Int, moving: Set<Int>
    ) -> (gap: Int, gone: CGFloat?)? {
        guard slots.count > 1, slots.indices.contains(gap) else { return nil }
        let still = slots.indices.filter { $0 != origin && !moving.contains($0) }
        guard !still.isEmpty else { return nil }
        let left = still.map { place(of: $0, origin: origin, gap: gap) }.filter { place in
            !middles.contains { abs($0 - slots[place]) <= watchTolerance }
        }
        guard CGFloat(still.count - left.count) >= CGFloat(still.count) * watchQuorum else { return nil }
        let after = left.filter { $0 > gap }
        let before = left.filter { $0 < gap }
        guard after.isEmpty || before.isEmpty else { return nil }
        guard let new = after.max() ?? before.min() else { return (gap, nil) }
        let from = new > gap ? gap + 1 : gap - 1
        let spacing = abs(slots[from] - slots[gap])
        let low = min(slots[from], slots[gap]) + watchTolerance
        let high = max(slots[from], slots[gap]) - watchTolerance
        let gone = middles.filter { $0 > low && $0 < high }.map { abs($0 - slots[from]) }.min()
        return (new, gone.map { $0 / spacing })
    }

    /// The middles of the evenly spaced places along a bar, from its thumbnails' middles, left to right,
    /// any one of which may be off its place, as a dragged one may be.
    static func slotCentres(_ middles: [CGFloat]) -> [CGFloat]? {
        guard middles.count > 1 else { return nil }
        guard middles.count > 3 else { return middles }
        let steps = zip(middles, middles.dropFirst()).map { $1 - $0 }.sorted()
        let spacing = steps[steps.count / 2]
        let firsts = middles.enumerated().map { $1 - CGFloat($0) * spacing }.sorted()
        let first = firsts[firsts.count / 2]
        return middles.indices.map { first + CGFloat($0) * spacing }
    }

    /// Where the thumbnail picked up at place `index` is with a dragged one, picked up from `origin`,
    /// at `gap`.
    static func place(of index: Int, origin: Int, gap: Int) -> Int {
        if index == origin { return gap }
        if gap < origin, (gap..<origin).contains(index) { return index + 1 }
        if gap > origin, (origin + 1...gap).contains(index) { return index - 1 }
        return index
    }

    /// How close to its place, in points, a caption shows to count as at rest there.
    private static let watchTolerance: CGFloat = 5
    /// The share of thumbnails at rest whose captions must show at their places for a frame to count.
    private static let watchQuorum: CGFloat = 0.6
    /// How long after a drag starts its captions are watched: until then the bar may still be sliding to
    /// the middle, and its captions passing others' places.
    private static let watchAfter: TimeInterval = 0.35
    /// A caption seen less than this far, in points, off its place has only just started moving: filmed,
    /// such a caption had nudged 6-8 points, and its move proper started 7-17ms after.
    private static let justStarted: CGFloat = 12
    private static let startAfterNudge: TimeInterval = 0.007
    /// How long a frame waits for the captions on screen: most arrive later, and are drawn as they do.
    private static let watchWait: TimeInterval = 0.002
    /// How tall a strip, in points, around the captions' middles is watched.
    private static let captionBand: CGFloat = 24

    /// Where a dragged thumbnail goes, its place having been `gap`, with its middle reckoned at `middleX`
    /// over thumbnails with middles at `centres`, left to right.
    static func dragGap(from gap: Int, centres: [CGFloat], middleX: CGFloat) -> Int {
        guard centres.count > 1 else { return gap }
        let crossing = middleX - makeRoomLead
        var gap = min(max(gap, 0), centres.count - 1)
        while gap + 1 < centres.count, crossing > centres[gap + 1] { gap += 1 }
        while gap > 0, crossing < centres[gap - 1] { gap -= 1 }
        return gap
    }

    /// How far right of a thumbnail's middle, in points, the Dock's reckoning of another dragged over it
    /// comes for the Dock to move it aside, whichever way the drag goes: 25-28 on macOS 26.7, over nine
    /// filmed moves with the thumbnails 162 and 174 apart.
    static let makeRoomLead: CGFloat = 26

    /// How much of the pointer's distance from a picked-up thumbnail's middle, as the drag starts, the
    /// Dock keeps between the pointer and its reckoning of the thumbnail's middle: fitted on macOS 26.7 to
    /// drags held 2 to 52 points off the middle, to within about 2 points.
    static let dragHold: CGFloat = 0.82

    /// How long after a drop the Dock has surely reordered the desktops, as Accessibility reports them:
    /// seen done within 40ms.
    private static let dropReorderTime: TimeInterval = 0.1

    /// How long after a dragged thumbnail is let go its caption shows: when it has settled in its place.
    /// Filmed on macOS 26.7 at 0.24-0.27s after two drops, before the window server says so.
    private static let dropSettle: TimeInterval = 0.25
}

/// A thumbnail dragged along its bar, and the others moving aside to make room for it.
struct ThumbnailDrag {
    let screen: CGRect
    /// The dragged thumbnail's space, if it has a label.
    let spaceID: String?
    /// The labelled spaces in their thumbnails' order when it was picked up, and each one's place.
    let order: [String]
    let places: [String: Int]
    /// Where it was picked up from, and where it would go if let go now.
    let origin: Int
    var gap: Int
    /// How far the pointer is across from where the Dock reckons the dragged thumbnail's middle.
    let grabOffset: CGFloat
    /// The labels moving aside, by space.
    var moves: [String: TimedMove] = [:]
    /// When it was picked up (system uptime).
    let startedAt: TimeInterval
    /// Whether Mission Control's own captions are being watched to tell where the Dock moves the others.
    var watched = false
    /// Until when each thumbnail, by its place as picked up, is moving aside.
    var movingUntil: [Int: TimeInterval] = [:]
    var dropped = false
    /// When the dragged thumbnail, let go, has settled in its place and shows its caption.
    var settlesAt: TimeInterval?
    /// When it was let go, and whether the Dock has reported the bars since.
    var droppedAt: TimeInterval?
    var reported = false

    init(bar: BarLayout, origin: Int, grabOffset: CGFloat, at time: TimeInterval) {
        screen = bar.screen
        startedAt = time
        let titles = bar.buttons.map(\.title)
        var places: [String: Int] = [:]
        for caption in bar.captions {
            if let index = titles.firstIndex(of: caption.covers) { places[caption.spaceID] = index }
        }
        self.places = places
        order = bar.captions.map(\.spaceID)
        spaceID = bar.captions.first { $0.covers == titles[origin] }?.spaceID
        self.origin = origin
        gap = origin
        self.grabOffset = grabOffset
    }

    /// The middle of the place the dragged thumbnail goes, worked out from the others': the Dock may
    /// report the dragged one where it is on its way there.
    func gapCentre(in bar: BarLayout) -> CGFloat? {
        let others = bar.buttons.indices.filter { $0 != gap }
        guard let first = others.first, let last = others.last, last > first else {
            return bar.buttons.indices.contains(gap) ? bar.buttons[gap].frame.midX : nil
        }
        let spacing = (bar.buttons[last].frame.midX - bar.buttons[first].frame.midX) / CGFloat(last - first)
        return bar.buttons[first].frame.midX + CGFloat(gap - first) * spacing
    }

    /// Where the thumbnail of `spaceID` is with the dragged one's place at `gap`, while `bar` still
    /// shows the thumbnails in the order they were picked up in. Once the Dock reports them reordered,
    /// they are where it reports them.
    func place(of spaceID: String, in bar: BarLayout) -> Int? {
        guard bar.captions.map(\.spaceID) == order, let place = places[spaceID] else { return nil }
        if spaceID == self.spaceID { return gap }
        return MissionControlLabels.place(of: place, origin: origin, gap: gap)
    }
}
