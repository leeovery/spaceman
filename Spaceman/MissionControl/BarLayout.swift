//
//  BarLayout.swift
//  Spaceman
//
//  The Spaces Bar as measured: each bar's thumbnails and captions, its screen, and the
//  changes to its desktops the labels follow.
//

import AppKit
import ApplicationServices

/// One Dock Spaces Bar's captions, measured once and then moved with the bar.
struct BarLayout {
    /// The bar and its first thumbnail; nil when carried over from an earlier session.
    let bar: AXUIElement?
    let firstButton: AXUIElement?
    /// Where the bar and its first thumbnail were when measured.
    let frame: CGRect
    var firstButtonX: CGFloat?
    /// The bar's screen, in AX coordinates, and its display.
    let screen: CGRect
    let displayID: CGDirectDisplayID
    var captions: [Caption]
    /// The bar's list of thumbnails, which knows the selected one, and each thumbnail's title and frame.
    var list: AXUIElement?
    var buttons: [(element: AXUIElement, title: String, frame: CGRect)] = []
    /// Each thumbnail's space, in the thumbnails' order, labelled or not; empty when they didn't match.
    var spaceIDs: [String] = []
    /// The last thumbnail and where it was, to tell the thumbnails sliding together from other changes.
    var lastButton: AXUIElement?
    var lastButtonX: CGFloat?
    /// The button that adds a desktop, in the screen's top corner.
    var addButton: CGRect?

    /// This layout with its thumbnails and captions `dx` further across.
    func offsetBy(dx: CGFloat) -> BarLayout {
        var moved = self
        moved.firstButtonX = firstButtonX.map { $0 + dx }
        moved.lastButtonX = lastButtonX.map { $0 + dx }
        moved.buttons = buttons.map { ($0.element, $0.title, $0.frame.offsetBy(dx: dx, dy: 0)) }
        moved.captions = captions.map { caption in
            var moved = caption
            moved.centre.x += dx
            return moved
        }
        return moved
    }

    /// This layout with its thumbnails in the middle of the screen, as the Dock settles them.
    func centred() -> BarLayout {
        guard let first = buttons.first?.frame, let last = buttons.last?.frame else { return self }
        return offsetBy(dx: ((screen.maxX - last.maxX) - (first.minX - screen.minX)) / 2)
    }

    /// This layout with the bar at rest, for showing before the Dock reports a bar.
    func atRest() -> BarLayout {
        let shift = screen.minY - frame.minY
        return BarLayout(
            bar: nil,
            firstButton: nil,
            frame: frame.offsetBy(dx: 0, dy: shift),
            firstButtonX: nil,
            screen: screen,
            displayID: displayID,
            captions: captions.map { caption in
                var moved = caption
                moved.centre.y += shift
                return moved
            },
            buttons: buttons.map { ($0.element, $0.title, $0.frame.offsetBy(dx: 0, dy: shift)) },
            spaceIDs: spaceIDs,
            addButton: addButton?.offsetBy(dx: 0, dy: shift))
    }

    /// `bar`'s labels at the places of this layout's thumbnails, for a bar with as many: each space's
    /// label goes to its thumbnail's place in `bar`, which may have been reordered since this was seen.
    func placing(_ bar: BarLayout) -> BarLayout {
        var placed = self
        placed.spaceIDs = bar.spaceIDs
        let centres = buttons.map { MissionControlLabels.captionCentre(below: $0.frame) }
        placed.captions = bar.captions.compactMap { caption in
            guard centres.indices.contains(caption.index) else { return nil }
            var moved = caption
            moved.centre = centres[caption.index]
            moved.maxWidth = MissionControlLabels.labelWidth(
                at: caption.index, centres: centres, fallbackWidth: buttons.first?.frame.width ?? 0)
            return moved
        }
        return placed
    }

    /// This layout with its thumbnails at `frames`, re-read as magnified thumbnails resize, and their
    /// captions moved under them, each as wide as its neighbours now leave room for. Nil, to measure
    /// everything, when the frames couldn't be read or the bar's list now holds `count` thumbnails, other
    /// than it did.
    func following(count: Int?, frames: [CGRect]?) -> BarLayout? {
        guard count == buttons.count, let frames, frames.count == buttons.count else { return nil }
        var followed = self
        followed.buttons = zip(buttons, frames).map { ($0.element, $0.title, $1) }
        followed.firstButtonX = frames.first?.minX
        followed.lastButtonX = frames.last?.minX
        let centres = frames.map(MissionControlLabels.captionCentre(below:))
        followed.captions = captions.map { caption in
            guard centres.indices.contains(caption.index) else { return caption }
            var moved = caption
            moved.centre = centres[caption.index]
            moved.maxWidth = MissionControlLabels.labelWidth(
                at: caption.index, centres: centres, fallbackWidth: frames.first?.width ?? 0)
            return moved
        }
        return followed
    }

    /// Whether the bar, now at `barFrame`, is where it was measured, within half a point.
    func isWhereMeasured(now barFrame: CGRect) -> Bool {
        abs(barFrame.minX - frame.minX) <= 0.5 && abs(barFrame.minY - frame.minY) <= 0.5
            && abs(barFrame.width - frame.width) <= 0.5 && abs(barFrame.height - frame.height) <= 0.5
    }

    /// Whether the bar, now at `barFrame` and at `previous` a reading before, has come to rest away from where
    /// it was measured, as when measured still landing: then it is measured again.
    func restsOffItsPlace(now barFrame: CGRect, before previous: CGRect?) -> Bool {
        guard let previous, !isWhereMeasured(now: barFrame) else { return false }
        return abs(barFrame.minX - previous.minX) <= 0.5 && abs(barFrame.minY - previous.minY) <= 0.5
            && abs(barFrame.width - previous.width) <= 0.5 && abs(barFrame.height - previous.height) <= 0.5
    }

    /// How far every thumbnail slid sideways together since `old`, the same bar measured before, or nil when
    /// they didn't all move by the same amount, within half a point, at the same widths.
    func thumbnailShift(since old: BarLayout) -> CGFloat? {
        guard frame == old.frame, let first = buttons.first, let firstBefore = old.buttons.first,
              buttons.count == old.buttons.count
        else { return nil }
        let dx = first.frame.minX - firstBefore.frame.minX
        let together = zip(old.buttons, buttons).allSatisfy { before, now in
            abs((now.frame.minX - before.frame.minX) - dx) <= 0.5 && abs(now.frame.width - before.frame.width) <= 0.5
        }
        return together ? dx : nil
    }

    /// Whether any thumbnail moved or resized by more than half a point since `old`, the same bar before.
    func thumbnailsMoved(since old: BarLayout) -> Bool {
        guard buttons.count == old.buttons.count else { return true }
        return zip(old.buttons, buttons).contains { before, now in
            abs(now.frame.minX - before.frame.minX) > 0.5 || abs(now.frame.minY - before.frame.minY) > 0.5
                || abs(now.frame.width - before.frame.width) > 0.5
                || abs(now.frame.height - before.frame.height) > 0.5
        }
    }

    /// This layout with its captions matched afresh from its thumbnails, with the names stored now and
    /// unnamed spaces labelled or not, as a session's style has it.
    func rematched(labelsUnnamed: Bool, storedNames: [String: SpaceNameInfo]) -> BarLayout {
        var layout = self
        layout.captions = MissionControlLabels.dockCaptions(
            buttons.map { ($0.element, $0.frame, $0.title) }, spaceIDs: spaceIDs, labelsUnnamed: labelsUnnamed,
            storedNames: storedNames
        ).captions
        return layout
    }
}

/// One name label's place over a "Desktop N" caption, in AX coordinates, and its space.
struct Caption {
    var centre: CGPoint
    var maxWidth: CGFloat
    /// Its thumbnail's place among the bar's: titles can repeat, as for two full-screen windows of one app.
    var index: Int
    let covers: String
    let name: String
    let colorHex: String?
    let spaceID: String
}

/// A screen's frame in AX coordinates, its display, the display's UUID and its pixels to the point, read on the
/// main thread for use on any.
struct ScreenInfo {
    let frame: CGRect
    let displayID: CGDirectDisplayID
    let uuid: String?
    let scale: CGFloat

    static func current() -> [ScreenInfo] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return ScreenInfo(
                frame: axFrame(of: screen), displayID: number?.uint32Value ?? 0,
                uuid: MissionControlLabels.displayUUID(of: screen), scale: screen.backingScaleFactor)
        }
    }

    static func axFrame(of screen: NSScreen) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let appKit = screen.frame
        return CGRect(x: appKit.minX, y: primaryTop - appKit.maxY, width: appKit.width, height: appKit.height)
    }
}

/// A click that adds a desktop, or removes the one at `index` among a bar's thumbnails.
enum DesktopChange: CustomStringConvertible {
    case add(screen: CGRect)
    case remove(screen: CGRect, index: Int)

    var screen: CGRect {
        switch self {
        case .add(let screen), .remove(let screen, _): return screen
        }
    }

    var description: String {
        switch self {
        case .add: return "add"
        case .remove(_, let index): return "remove \(index + 1)"
        }
    }
}

/// Labels moving as a desktop comes or goes, from where each space's thumbnail was.
struct Reflow {
    let screen: CGRect
    let timing: DockMotion.Timing
    let reference: TimeInterval
    let from: [String: CGPoint]
    /// The spaces the bar showed before, by its thumbnails; empty when they weren't known.
    let spacesBefore: [String]
    /// How many thumbnails the bar will have.
    let count: Int
    /// Where the labels go until the Dock reports the thumbnails.
    var predicted: BarLayout?

    /// Whether `caption`'s label waits for the move to end, its space being new to the bar: shown at once,
    /// it would sit still while the others move. Without the spaces from before, none waits.
    func holds(_ caption: Caption) -> Bool {
        !spacesBefore.isEmpty && !spacesBefore.contains(caption.spaceID)
    }

    /// Where `caption`'s label moves from, or nil if it had none before.
    func move(of caption: Caption) -> TimedMove? {
        from[caption.spaceID].map {
            TimedMove(timing: timing, reference: reference, from: CGVector(dx: $0.x - caption.centre.x, dy: 0))
        }
    }
}
