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
    /// Only the label of the thumbnail at this place: the hovered one, on a magnifying bar.
    case only(Int)
    /// None: the pointer is off a magnifying bar.
    case none

    /// A bar's labels: all of them, unless its thumbnails `magnifies`. Then only the hovered thumbnail's,
    /// while `pointer` (AX coordinates) is within the bar's height with the bar at rest.
    static func on(_ bar: BarLayout, magnifies: Bool, pointer: CGPoint?) -> ShownLabels {
        guard magnifies else { return .all }
        let top = bar.screen.minY
        guard let pointer, (top...(top + bar.frame.height)).contains(pointer.y),
              let place = hoveredThumbnail(bar.buttons.map(\.frame), at: pointer.x)
        else { return .none }
        return .only(place)
    }

    /// The thumbnail of `frames`, left to right, whose span out to the middle of the gap on each side
    /// holds `x`. macOS moves the caption on as the pointer crosses the middle of a gap: from there on it
    /// is the next thumbnail's. Past the outer edge of either end thumbnail, none.
    static func hoveredThumbnail(_ frames: [CGRect], at x: CGFloat) -> Int? {
        frames.indices.first { index in
            let left = index > frames.startIndex ? (frames[index - 1].maxX + frames[index].minX) / 2
                : frames[index].minX
            let right = index < frames.endIndex - 1 ? (frames[index].maxX + frames[index + 1].minX) / 2
                : frames[index].maxX
            return left <= x && x < right
        }
    }

    func shows(_ caption: Caption) -> Bool {
        switch self {
        case .all: return true
        case .only(let place): return caption.index == place
        case .none: return false
        }
    }
}

extension BarLayout {
    /// This bar with only the captions whose labels `shown` draws.
    func showing(_ shown: ShownLabels) -> BarLayout {
        var showing = self
        showing.captions = captions.filter(shown.shows)
        return showing
    }
}
