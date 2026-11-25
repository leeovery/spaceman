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
        let drawn = caption.map { caption in labels.contains { $0.name == caption.name && $0.screen == drag.screen } }
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
        let kind = found.map { $0.exact ? "exact" : $0.sameHeight ? "this height" : "other height" } ?? "none"
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
            let look = label.look == nil ? "box" : (looks[Self.lookKeys(bar: bar, caption: caption).exact] != nil
                ? "exact" : "borrowed")
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
