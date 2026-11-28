//
//  MissionControlLabels+Debug.swift
//  Spaceman
//
//  Notes for the debug motion recording, and traces of where the labels go.
//

import AppKit
import os

extension MissionControlLabels {

    /// Notes `text` in the debug motion recording, when it is on.
    func record(
        _ text: @autoclosure () -> String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard MissionControlMotionRecorder.isEnabled else { return }
        MissionControlMotionRecorder.shared.note(text(), at: time)
    }

    /// Notes in the debug motion recording, when it is on, where each label is placed for the frame
    /// reaching the screen at `frameTime`; none, once they are hidden.
    func recordDrawn(at frameTime: TimeInterval) {
        guard MissionControlMotionRecorder.isEnabled else { return }
        MissionControlMotionRecorder.shared.noteDrawn(overlay.drawnLabels(at: frameTime), at: frameTime)
    }

    /// Notes in the debug motion recording, when it is on and it changes, which labels each bar shows: all,
    /// or on a magnifying bar those shown about the hovered thumbnail, by their spaces left to right, or none.
    func recordShown(_ shownByBar: [(bar: BarLayout, shown: ShownLabels)], at frameTime: TimeInterval) {
        guard MissionControlMotionRecorder.isEnabled else { return }
        let line = "labels shown: "
            + shownByBar.map { Self.shownRecord(bar: $0.bar, shown: $0.shown) }.joined(separator: ", ")
        guard line != lastShownRecord else { return }
        lastShownRecord = line
        record(line, at: frameTime)
    }

    /// "display <id> all", "display <id> none", or "display <id> hovered 9+10": the spaces whose labels `bar` shows.
    static func shownRecord(bar: BarLayout, shown: ShownLabels) -> String {
        let which: String
        switch shown {
        case .all: which = "all"
        case .none: which = "none"
        case .only:
            which = "hovered " + shown.places.map {
                bar.spaceIDs.indices.contains($0) ? bar.spaceIDs[$0] : "place \($0 + 1)"
            }.joined(separator: "+")
        }
        return "display \(bar.displayID) \(which)"
    }

    /// "display <id> thumbnails <x>,<width> ...": each thumbnail's left edge and width as the Dock last reported
    /// them, in points, to check a magnifying bar's against the film.
    static func thumbnailFrames(of bar: BarLayout) -> String {
        "display \(bar.displayID) thumbnails " + bar.buttons.map {
            String(format: "%.1f,%.1f", $0.frame.minX, $0.frame.width)
        }.joined(separator: " ")
    }

    /// Has WindowManager's Spaces Bar buttons read for the debug recording, when it is on, and the Dock's
    /// with `missionControlMotionDockButtons` too: each probe reads off the main thread, as often as its app
    /// answers, at most once a frame. The Dock's is off by default, as it delays the labels' own readings.
    func recordBars() {
        guard MissionControlMotionRecorder.isEnabled else { return }
        if let pid = pid(of: "com.apple.WindowManager") { windowManagerProbe.request(pid: pid) }
        if UserDefaults.standard.bool(forKey: "missionControlMotionDockButtons"), let pid = pid(of: "com.apple.dock") {
            dockProbe.request(pid: pid)
        }
    }

    /// WindowManager's Spaces Bars, found as `poll()` finds them on macOS 27. Any thread.
    static func windowManagerBars(in windowManager: AXUIElement) -> [AXUIElement] {
        AX.spacesBars(in: windowManager, depthLimit: 2) { AX.identifier(of: $0) == "mc.spaces" }
    }

    /// The Dock's Spaces Bars, found as the Dock reader finds them. Any thread.
    static func dockBars(in dock: AXUIElement) -> [AXUIElement] {
        AX.children(of: dock).filter { AX.title(of: $0) == "Mission Control" }.flatMap { missionControl in
            AX.spacesBars(in: missionControl, depthLimit: 3) { AX.title(of: $0) == "Spaces Bar" }
        }
    }

    func recordPointer() {
        guard MissionControlMotionRecorder.isEnabled else { return }
        let point = NSEvent.mouseLocation
        guard point != lastPointerRecord else { return }
        lastPointerRecord = point
        record(String(format: "pointer %.0f %.0f", point.x, point.y))
    }

    func recordSwipe() {
        let state: String
        switch swipe.state {
        case .idle: state = "idle"
        case .swiping: state = "swiping"
        case let .released(_, released, _, velocity):
            state = String(format: "released %.3f at %.2f/s", released, velocity)
        }
        let line = "swipe \(state)" + (swipe.gesture == confirmedGesture ? " taken" : "")
        guard line != lastSwipeRecord else { return }
        lastSwipeRecord = line
        record(line)
    }

    /// Notes, for the debug recording, whether a dragged thumbnail's label is drawn, when that changes.
    func traceDrag(_ bars: [BarLayout], labels: [MissionControlLabel], at time: TimeInterval) {
        guard let drag else {
            lastDragTrace = nil
            return
        }
        let bar = bars.first { $0.screen == drag.screen }
        let caption = bar?.captions.first { $0.spaceID == drag.spaceID }
        let drawn = caption.map { caption in labels.contains { $0.key == caption.spaceID && $0.screen == drag.screen } }
        let line = "drag of space \(drag.spaceID ?? "none"): bar \(bar == nil ? "missing" : "found"), caption "
            + "\(caption.map { "\($0.covers) at \(Int($0.centre.x.rounded()))" } ?? "missing"), label "
            + "\(drawn.map { $0 ? "drawn" : "hidden" } ?? "-"), gap \(drag.gap), dropped \(drag.dropped)"
        guard line != lastDragTrace else { return }
        lastDragTrace = line
        record(line + "; " + overlay.layerState(for: drag.screen), at: time)
    }

    /// Notes, for the debug recording, how the dropped thumbnail's label is drawn for a second after.
    func traceDropped(
        _ caption: Caption, label: MissionControlLabel, look found: FoundLook?, at time: TimeInterval,
        since: TimeInterval
    ) {
        guard time - since < 1.2 else {
            droppedSpace = nil
            return
        }
        let kind = found.map { $0.exact ? "exact" : "by name" } ?? "none"
        let origin = label.lookOrigin.map { String(format: "%.0f,%.0f", $0.x, $0.y) } ?? "centred"
        record(String(format: "dropped %@ %@, caption %.0f,%.0f, look %@ at %@", caption.name, caption.covers,
                      caption.centre.x, caption.centre.y, kind, origin), at: time)
    }

    /// Logs where the labels over the first bar's first two captions go, when it changes.
    func trace(_ bar: BarLayout?, labels: [MissionControlLabel], retraction: CGFloat) {
        guard let bar else { return }
        let parts = bar.captions.prefix(2).map { caption in
            guard let label = labels.first(where: { $0.key == caption.spaceID && $0.screen == bar.screen }) else {
                return "\(caption.covers) at x \(Int(caption.centre.x.rounded())) not covered"
            }
            let look = label.strip != nil ? "strip" : label.look == nil ? "box"
                : captionLooks.look(for: caption, on: bar)?.exact == true ? "exact" : "borrowed"
            let lift = retraction * bar.frame.height
            let drawn = label.lookOrigin.map { "\(Int($0.x.rounded())),\(Int(($0.y - lift).rounded()))" } ?? "centred"
            return "\(caption.covers) at x \(Int(caption.centre.x.rounded())) drawn \(drawn) \(look)"
        }
        let state: String
        switch swipe.state {
        case .idle: state = "idle"
        case .swiping(let value): state = String(format: "swiping %.3f", value)
        case .released(_, let value, _, _): state = String(format: "released %.3f", value)
        }
        let line = String(format: "v%d bar %.0f,%.0f %.0fx%.0f r=%.3f %@: ", layoutsVersion, bar.frame.minX,
                          bar.frame.minY, bar.frame.width, bar.frame.height, retraction, state)
            + parts.joined(separator: "; ") + "; windows " + overlay.debugState
        guard line != lastTrace else { return }
        lastTrace = line
        Self.log.log("\(line, privacy: .public)")
    }
}
