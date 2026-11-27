//
//  BarMagnification.swift
//  Spaceman
//
//  Expanded bars whose thumbnails macOS magnifies under the pointer, as the Dock does its icons, once
//  too many desktops share a screen to fit at full size; and which of a bar's labels are drawn.
//

import AppKit

/// Which expanded bars magnify, by screen and number of thumbnails, learned from the Dock's reports and
/// kept for the run, so a later session knows from the first frame of the grow. macOS draws a magnifying
/// bar's caption only under the hovered thumbnail. A bar not yet known is labelled as one that doesn't
/// magnify, and its thumbnails are followed as a magnifying bar's, so one reading tells.
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

    /// A bar's screen, by display and width, and its number of thumbnails: whether its thumbnails fit
    /// at full size.
    static func key(of bar: BarLayout) -> String {
        "\(bar.displayID)|\(Int(bar.screen.width.rounded()))|\(bar.buttons.count)"
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
        bar.frame.height > MissionControlLabels.expandedBarHeight && learned[Self.key(of: bar)] == .magnifies
    }

    /// Whether `bar`'s thumbnails are read one by one as they resize: thumbnails known to magnify, or not
    /// known yet. Never a bar of names, nor thumbnails known not to magnify.
    func follows(_ bar: BarLayout) -> Bool {
        bar.frame.height > MissionControlLabels.expandedBarHeight && learned[Self.key(of: bar)] != .doesNotMagnify
    }

    /// Learns from `bar` as the Dock reported it in a reading taken at `read`, with the pointer at `pointer`
    /// (AX coordinates) at `time` and nothing else moving its thumbnails. Thumbnails of different widths with
    /// the pointer over the bar show that it magnifies. Thumbnails of one width with the pointer on one show
    /// that it doesn't, once a reading taken `evenWidthsTime` after the pointer came onto it still has them
    /// so: a reading older than that, from a Dock slow to answer, may predate the pointer. That undoes a
    /// wrong guess. Returns what it learned, when that changed.
    mutating func learn(from bar: BarLayout, read: TimeInterval, pointer: CGPoint?, at time: TimeInterval)
        -> Learned? {
        let key = Self.key(of: bar)
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

    /// How many frames the pointer is ahead of the labels: macOS moves its caption the instant the pointer crosses
    /// the middle of a gap, and a label drawn from the pointer reaches the screen up to two frames later.
    static let framesBehind = 2
    /// The least distance either side of a gap's middle in which a moving pointer shows both thumbnails' labels.
    static let leastReach: CGFloat = 3

    /// A bar's labels: all of them, unless its thumbnails `magnifies`. Then the hovered thumbnail's, while
    /// `pointer` (AX coordinates) is within the bar's height; with both thumbnails beside each gap whose middle is
    /// within `reach` of the pointer, and the one at `kept`, which the hover has just left.
    static func on(
        _ bar: BarLayout, magnifies: Bool, pointer: CGPoint?, reach: CGFloat = 0, keeping kept: Int? = nil
    ) -> ShownLabels {
        guard magnifies else { return .all }
        let top = bar.screen.minY
        let frames = bar.buttons.map(\.frame)
        guard let pointer, (top...(top + bar.frame.height)).contains(pointer.y),
              let place = hoveredThumbnail(frames, at: pointer.x)
        else { return .none }
        let near = frames.indices.dropLast().filter { abs(gapMiddle(after: $0, in: frames) - pointer.x) < reach }
        var also = Set(near.flatMap { [$0, $0 + 1] })
        if let kept, frames.indices.contains(kept) { also.insert(kept) }
        also.remove(place)
        return .only(place, also: also)
    }

    /// How far either side of a gap's middle a pointer moving at `speed` (points a second) shows both thumbnails'
    /// labels: as far as it moves in `framesBehind` frames of `frameDuration`, and at least `leastReach`. None for a
    /// pointer at rest, which shows only the hovered thumbnail's.
    static func reach(speed: CGFloat, frameDuration: TimeInterval) -> CGFloat {
        guard speed > 0 else { return 0 }
        return max(leastReach, speed * CGFloat(frameDuration) * CGFloat(framesBehind))
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

    /// The pointer's speed across the bars, in points a second, either way.
    var speed: CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return abs(last.x - first.x) / CGFloat(last.time - first.time)
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
