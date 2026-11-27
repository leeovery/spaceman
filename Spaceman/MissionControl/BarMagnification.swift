//
//  BarMagnification.swift
//  Spaceman
//
//  Expanded bars whose thumbnails macOS magnifies under the pointer, as the Dock does its icons, once
//  too many desktops share a screen to fit at full size; and which of a bar's labels are drawn.
//

import AppKit

/// Which expanded bars magnify, by screen and number of thumbnails, learned from the Dock's reports and
/// kept for the run and on disk, so a later session, even the first after a launch, knows from the first frame
/// of the grow. macOS draws a magnifying bar's caption only under the hovered thumbnail. A bar not yet known is
/// labelled as one that doesn't magnify, and its thumbnails are followed as a magnifying bar's, so one reading
/// tells.
struct BarMagnification {

    enum Learned: Equatable {
        case magnifies
        case doesNotMagnify
    }

    /// How far apart the widest and narrowest thumbnails may be on a bar that doesn't magnify. A magnified
    /// thumbnail and its neighbours are 20pt or more off the others' width (measured on macOS 26.7 with 16
    /// desktops on a 2560-point screen); a bar that doesn't magnify has them all the same.
    static let widthTolerance: CGFloat = 2
    /// How long the thumbnails must stay one width, with the pointer over one, to show the bar doesn't
    /// magnify: a magnifying bar always has the one under the pointer grown.
    static let evenWidthsTime: TimeInterval = 0.3

    private var learned: [String: Learned] = [:]
    /// Since when the pointer has been on one of each bar's thumbnails, all one width, without a break.
    private var evenSince: [String: TimeInterval] = [:]
    /// Each display's UUID, which, unlike its ID, stays the same from one launch to the next.
    private var displays: [CGDirectDisplayID: String] = [:]

    /// A bar's screen, by display and width, and its number of thumbnails, for the run.
    static func key(of bar: BarLayout) -> String {
        "\(bar.displayID)|\(Int(bar.screen.width.rounded()))|\(bar.buttons.count)"
    }

    /// What is learned of `bar` is kept by: its screen, by display UUID and width, and its number of thumbnails,
    /// whether its thumbnails fit at full size. A display whose UUID isn't known goes by its ID, for the run only.
    private func learnedKey(of bar: BarLayout) -> String {
        "\(displays[bar.displayID] ?? "#\(bar.displayID)")|\(Int(bar.screen.width.rounded()))|\(bar.buttons.count)"
    }

    /// What has been learned of bars on displays known by UUID, to keep on disk.
    var kept: [String: Learned] {
        learned.filter { !$0.key.hasPrefix("#") }
    }

    /// Notes the displays `screens` are on, by UUID.
    mutating func know(_ screens: [ScreenInfo]) {
        for screen in screens {
            if let uuid = screen.uuid { displays[screen.displayID] = uuid }
        }
    }

    /// Takes what was learned in earlier runs, for bars this run hasn't learned about.
    mutating func adopt(_ stored: [String: Learned]) {
        learned.merge(stored) { current, _ in current }
    }

    /// Whether `bar` shows thumbnails that differ in width, as only magnified ones do.
    static func showsMagnification(_ bar: BarLayout) -> Bool {
        let widths = bar.buttons.map(\.frame.width)
        guard bar.frame.height > MissionControlLabels.expandedBarHeight, let widest = widths.max(),
              let narrowest = widths.min()
        else { return false }
        return widest - narrowest > widthTolerance
    }

    /// Whether `bar` shows thumbnails known to magnify: never a bar of names.
    func magnifies(_ bar: BarLayout) -> Bool {
        bar.frame.height > MissionControlLabels.expandedBarHeight && learned[learnedKey(of: bar)] == .magnifies
    }

    /// Whether `bar`'s thumbnails are read one by one as they resize: thumbnails known to magnify, or not
    /// known yet. Never a bar of names, nor thumbnails known not to magnify.
    func follows(_ bar: BarLayout) -> Bool {
        bar.frame.height > MissionControlLabels.expandedBarHeight && learned[learnedKey(of: bar)] != .doesNotMagnify
    }

    /// Learns from `bar` as the Dock reported it in a reading taken at `read`, with the pointer at `pointer`
    /// (AX coordinates) at `time` and nothing else moving its thumbnails. Thumbnails of different widths with
    /// the pointer over the bar show that it magnifies. Thumbnails of one width with the pointer on one show
    /// that it doesn't, once a reading taken `evenWidthsTime` after the pointer came onto it still has them
    /// so: a reading older than that, from a Dock slow to answer, may predate the pointer. That undoes a
    /// wrong guess. Returns what it learned, when that changed.
    mutating func learn(from bar: BarLayout, read: TimeInterval, pointer: CGPoint?, at time: TimeInterval)
        -> Learned? {
        let key = learnedKey(of: bar)
        let top = bar.screen.minY
        guard bar.frame.height > MissionControlLabels.expandedBarHeight, let pointer,
              (top...(top + bar.frame.height)).contains(pointer.y),
              (bar.frame.minX...bar.frame.maxX).contains(pointer.x)
        else {
            evenSince[key] = nil
            return nil
        }
        if Self.showsMagnification(bar) {
            evenSince[key] = nil
            return settle(key, as: .magnifies)
        }
        guard bar.buttons.contains(where: { $0.frame.contains(pointer) }) else {
            evenSince[key] = nil
            return nil
        }
        let since = evenSince[key] ?? time
        evenSince[key] = since
        return read - since >= Self.evenWidthsTime ? settle(key, as: .doesNotMagnify) : nil
    }

    /// Breaks every bar's run of even widths, as while something else moves the thumbnails.
    mutating func interrupt() {
        evenSince = [:]
    }

    private mutating func settle(_ key: String, as found: Learned) -> Learned? {
        guard learned[key] != found else { return nil }
        learned[key] = found
        return found
    }
}

/// Which of a bar's labels are drawn.
enum ShownLabels: Equatable {
    case all
    /// Only the label of the thumbnail at this place, the hovered one on a magnifying bar, and those at the places
    /// `also`: either side of a gap the pointer is about to cross, and the one it has just left, so whichever macOS
    /// captions in the frames the pointer is ahead of the labels is covered.
    case only(Int, also: Set<Int> = [])
    /// None: the pointer is off a magnifying bar.
    case none

    /// How the pointer and a bar's gaps between thumbnails move, in points a second, rightwards positive, and how far
    /// ahead a crossing counts as about to happen.
    struct Approach: Equatable {
        var pointer: CGFloat = 0
        /// By gap, left to right: none where not known, as still.
        var gaps: [CGFloat] = []
        var horizon: TimeInterval = 0

        static let still = Approach()

        /// The approach of a pointer moving at `pointer` to gaps moving at `gaps`, crossings `framesAhead` frames of
        /// `frameDuration` ahead counting as about to happen.
        static func of(pointer: CGFloat, gaps: [CGFloat], frameDuration: TimeInterval) -> Approach {
            Approach(pointer: pointer, gaps: gaps, horizon: Double(framesAhead) * frameDuration)
        }

        /// Whether the pointer at `x` crosses the middle at `middle` of the gap at `index` within `horizon`, or is
        /// within `leastReach` of it, moving.
        func crossesSoon(_ middle: CGFloat, gap index: Int, from x: CGFloat) -> Bool {
            guard pointer != 0 else { return false }
            let offset = middle - x
            if abs(offset) < ShownLabels.leastReach { return true }
            let closing = pointer - (gaps.indices.contains(index) ? gaps[index] : 0)
            guard closing != 0 else { return false }
            let time = TimeInterval(offset / closing)
            return time >= 0 && time <= horizon
        }
    }

    /// How many frames ahead of the pointer's crossing of a gap's middle both thumbnails' labels are drawn. macOS
    /// moves its caption as soon as 8ms after the pointer crosses, and a label drawn from the pointer reaches the
    /// screen a frame after it is read; drawn this far ahead, it is there at least two frames before macOS's swap
    /// (filmed on macOS 26.7, every crossing of 16 desktops swept at 1200-2300pt a second).
    static let framesAhead = 4
    /// The least distance either side of a gap's middle in which a moving pointer shows both thumbnails' labels.
    static let leastReach: CGFloat = 3

    /// A bar's labels: all of them, unless its thumbnails `magnifies`. Then the hovered thumbnail's, while
    /// `pointer` (AX coordinates) is within the bar's height; with both thumbnails beside each gap the pointer
    /// crosses soon on its `approach`, and the one at `kept`, which the hover has just left.
    static func on(
        _ bar: BarLayout, magnifies: Bool, pointer: CGPoint?, approach: Approach = .still, keeping kept: Int? = nil
    ) -> ShownLabels {
        guard magnifies else { return .all }
        let top = bar.screen.minY
        let frames = bar.buttons.map(\.frame)
        guard let pointer, (top...(top + bar.frame.height)).contains(pointer.y),
              let place = hoveredThumbnail(frames, at: pointer.x)
        else { return .none }
        let near = gapMiddles(frames).enumerated().filter { index, middle in
            approach.crossesSoon(middle, gap: index, from: pointer.x)
        }
        var also = Set(near.flatMap { [$0.offset, $0.offset + 1] })
        if let kept, frames.indices.contains(kept) { also.insert(kept) }
        also.remove(place)
        return .only(place, also: also)
    }

    /// The middles of the gaps between `frames`, left to right.
    static func gapMiddles(_ frames: [CGRect]) -> [CGFloat] {
        frames.indices.dropLast().map { gapMiddle(after: $0, in: frames) }
    }

    /// The thumbnail of `frames`, left to right, whose span out to the middle of the gap on each side
    /// holds `x`. macOS moves the caption on as the pointer crosses the middle of a gap: from there on it
    /// is the next thumbnail's. The end thumbnails' spans reach as far outwards, half the bar's gap past their
    /// outer edges; past those, none.
    static func hoveredThumbnail(_ frames: [CGRect], at x: CGFloat) -> Int? {
        guard let first = frames.first, let last = frames.last,
              first.minX - gap(frames.prefix(2)) / 2 <= x, x < last.maxX + gap(frames.suffix(2)) / 2
        else { return nil }
        return frames.indices.dropLast().first { x < gapMiddle(after: $0, in: frames) } ?? frames.endIndex - 1
    }

    /// The middle of the gap between the thumbnail at `index` of `frames` and the next.
    private static func gapMiddle(after index: Int, in frames: [CGRect]) -> CGFloat {
        (frames[index].maxX + frames[index + 1].minX) / 2
    }

    /// The gap between the two thumbnails of `pair`: none for a lone thumbnail.
    private static func gap(_ pair: ArraySlice<CGRect>) -> CGFloat {
        guard pair.count == 2, let left = pair.first, let right = pair.last else { return 0 }
        return max(0, right.minX - left.maxX)
    }

    /// The hovered thumbnail's place, on a magnifying bar.
    var hovered: Int? {
        guard case .only(let place, _) = self else { return nil }
        return place
    }

    /// Every place whose label is drawn on a magnifying bar, left to right.
    var places: [Int] {
        guard case .only(let place, let also) = self else { return [] }
        return also.union([place]).sorted()
    }

    func shows(_ caption: Caption) -> Bool {
        switch self {
        case .all: return true
        case .only(let place, let also): return caption.index == place || also.contains(caption.index)
        case .none: return false
        }
    }
}

/// How fast the pointer moves across the bars, from where it was over the last few frames.
struct PointerPace {

    /// How far back the pointer's places count towards its speed: three frames at 60 a second.
    static let window: TimeInterval = 0.05

    private var samples: [(time: TimeInterval, x: CGFloat)] = []

    /// Notes the pointer at `point` (AX coordinates), or nowhere, at `time`: once a frame, moved or not, so a
    /// pointer come to rest has its speed fall to none.
    mutating func note(_ point: CGPoint?, at time: TimeInterval) {
        guard let point else {
            samples = []
            return
        }
        samples.removeAll { $0.time < time - Self.window || $0.time > time }
        samples.append((time, point.x))
    }

    /// The pointer's velocity across the bars, in points a second, rightwards positive.
    var velocity: CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.x - first.x) / CGFloat(last.time - first.time)
    }

    /// The pointer's speed across the bars, in points a second, either way.
    var speed: CGFloat { abs(velocity) }
}

/// How fast the gaps between a magnifying bar's thumbnails move, from the Dock's readings of the bar: as the pointer
/// nears an end of the bar, the thumbnails there slide towards it.
struct GapPace {

    /// How far apart the readings compared are at least: the Dock repeats a reading for a frame now and then.
    static let span: TimeInterval = 0.03
    /// How long readings are kept.
    private static let kept: TimeInterval = 0.1

    private var samples: [(time: TimeInterval, middles: [CGFloat])] = []

    /// Notes `bar` as the Dock read it at `time`. A reading of another number of thumbnails starts afresh.
    mutating func note(_ bar: BarLayout, at time: TimeInterval) {
        let middles = ShownLabels.gapMiddles(bar.buttons.map(\.frame))
        if samples.last?.middles.count != middles.count { samples = [] }
        guard samples.last.map({ time > $0.time }) ?? true else { return }
        samples.removeAll { $0.time < time - Self.kept }
        samples.append((time, middles))
    }

    /// Each gap's velocity, left to right, in points a second, rightwards positive: from the latest reading and the
    /// latest at least `span` before it. None until there are two.
    var velocities: [CGFloat] {
        guard let last = samples.last,
              let earlier = samples.last(where: { $0.time <= last.time - Self.span })
        else { return [] }
        let elapsed = CGFloat(last.time - earlier.time)
        return zip(last.middles, earlier.middles).map { ($0 - $1) / elapsed }
    }
}

/// A magnifying bar's hovered thumbnail as last drawn, and the one the hover last left with the frame it left in:
/// that one's label stays for `keptFrames` frames more, as macOS may caption it in the frames the pointer is ahead.
struct HoverTrail: Equatable {

    static let keptFrames = 2

    private(set) var hovered: Int?
    private(set) var left: Int?
    private(set) var leftAt: TimeInterval = 0

    /// Notes `place` hovered, or none, in the frame reaching the screen at `time`. The hover moving on to another
    /// thumbnail keeps the one it left; moving off the thumbnails keeps none.
    mutating func note(_ place: Int?, at time: TimeInterval) {
        guard place != hovered else { return }
        left = place == nil ? nil : hovered
        leftAt = time
        hovered = place
    }

    /// The place whose label is kept in the frame reaching the screen at `time`, frames lasting `frameDuration`:
    /// the one the hover left, in the frame it left in and the `keptFrames` after. Counted by time, half a frame
    /// spare, so a frame drawn a little late still counts as the one it is.
    func kept(at time: TimeInterval, frameDuration: TimeInterval) -> Int? {
        guard let left, time - leftAt < (Double(Self.keptFrames) + 0.5) * frameDuration else { return nil }
        return left
    }
}
