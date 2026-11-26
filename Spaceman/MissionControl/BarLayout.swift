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

/// A screen's frame in AX coordinates, its display and the display's UUID, read on the main thread
/// for use on any.
struct ScreenInfo {
    let frame: CGRect
    let displayID: CGDirectDisplayID
    let uuid: String?

    static func current() -> [ScreenInfo] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return ScreenInfo(
                frame: axFrame(of: screen), displayID: number?.uint32Value ?? 0,
                uuid: MissionControlLabels.displayUUID(of: screen))
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
    /// How many thumbnails the bar will have.
    let count: Int
    /// Where the labels go until the Dock reports the thumbnails.
    var predicted: BarLayout?

    /// Where `caption`'s label moves from, or nil if it had no label before, as a desktop just added.
    func move(of caption: Caption) -> TimedMove? {
        from[caption.spaceID].map {
            TimedMove(timing: timing, reference: reference, from: CGVector(dx: $0.x - caption.centre.x, dy: 0))
        }
    }
}
