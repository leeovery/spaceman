//
//  BarMagnification.swift
//  Spaceman
//
//  Expanded bars whose thumbnails macOS magnifies under the pointer, as the Dock does its icons, once
//  too many desktops share a screen to fit at full size; and which of a bar's labels are drawn.
//

import AppKit

/// The expanded bars that magnify, by screen and number of thumbnails, learned from the Dock's reports
/// and kept for the run, so a later session knows from the first frame of the grow. macOS draws a
/// magnifying bar's caption only under the hovered thumbnail.
struct BarMagnification {

    /// How far apart the widest and narrowest thumbnails may be on a bar that doesn't magnify. A magnified
    /// thumbnail and its neighbours are 20pt or more off the others' width (measured on macOS 26.7 with 16
    /// desktops on a 2560-point screen); a bar that doesn't magnify has them all the same.
    static let widthTolerance: CGFloat = 2

    private var magnifying: Set<String> = []

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

    /// Whether `bar` shows thumbnails that magnify: never a bar of names.
    func magnifies(_ bar: BarLayout) -> Bool {
        bar.frame.height > MissionControlLabels.expandedBarHeight && magnifying.contains(Self.key(of: bar))
    }

    /// Learns from a Dock report of `bar`: true when it newly shows that bars like it magnify.
    mutating func learn(from bar: BarLayout) -> Bool {
        Self.showsMagnification(bar) && magnifying.insert(Self.key(of: bar)).inserted
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
