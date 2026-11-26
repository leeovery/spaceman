//
//  SpacesBarProbe.swift
//  Spaceman
//
//  Debug only, behind the missionControlMotionRecord default: reads an app's Spaces Bar buttons on a
//  queue of its own and notes every button's raw AX frame in the motion recording, so a run can compare
//  what the Dock and WindowManager each report of the bar as it moves.
//

import AppKit
import ApplicationServices

/// Reads one app's Spaces Bar buttons whenever asked and not already reading, so as often as the app
/// answers and never more than it is asked. Never waits on the app from the asking thread.
final class SpacesBarProbe {

    /// The app's bars, found from its application element.
    typealias FindBars = (AXUIElement) -> [AXUIElement]

    /// Short, so a busy app costs a reading, not a stalled queue.
    private static let messagingTimeout: Float = 0.05

    private let tag: String
    private let findBars: FindBars
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var inFlight = false
    // Used only on `queue`.
    private var app: (pid: pid_t, element: AXUIElement)?
    private var bars: [AXUIElement] = []

    /// A probe whose lines start with `tag`.
    init(tag: String, findBars: @escaping FindBars) {
        self.tag = tag
        self.findBars = findBars
        queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).probe.\(tag)", qos: .utility)
    }

    /// Reads the bars of the app `pid` unless a reading is under way. Any thread.
    func request(pid: pid_t) {
        lock.lock()
        guard !inFlight else {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        queue.async { [self] in
            read(pid: pid)
            lock.lock()
            inFlight = false
            lock.unlock()
        }
    }

    private func read(pid: pid_t) {
        if app?.pid != pid {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            app = (pid, element)
            bars = []
        }
        guard let app else { return }
        let started = ProcessInfo.processInfo.systemUptime
        var found = bars.map(AX.buttons(in:)).filter { !$0.isEmpty }
        // The bars found last are gone, as when Mission Control has closed since: look for them afresh.
        if found.isEmpty {
            bars = findBars(app.element)
            found = bars.map(AX.buttons(in:)).filter { !$0.isEmpty }
        }
        guard !found.isEmpty else { return }
        let finished = ProcessInfo.processInfo.systemUptime
        let buttons = found.map { $0.map { (title: $0.title, frame: $0.frame) } }
        MissionControlMotionRecorder.shared.note(
            Self.line(tag, bars: buttons), at: (started + finished) / 2)
    }

    /// `tag`, then each bar's buttons as "<title>@<x>,<y>,<width>,<height>", their raw AX frames in points
    /// to a tenth, with "|" between bars.
    static func line(_ tag: String, bars: [[(title: String, frame: CGRect)]]) -> String {
        tag + " " + bars.map { buttons in
            buttons.map { button in
                let frame = button.frame
                return String(
                    format: "%@@%.1f,%.1f,%.1f,%.1f", button.title, frame.minX, frame.minY, frame.width,
                    frame.height)
            }.joined(separator: " ")
        }.joined(separator: " | ")
    }
}
