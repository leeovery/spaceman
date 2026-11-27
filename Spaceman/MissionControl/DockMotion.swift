//
//  DockMotion.swift
//  Spaceman
//
//  How the Dock moves Mission Control's Spaces Bar where it reports only where the bar ends up:
//  opening and closing from the keyboard, a hot corner or a click. Each motion starts a fixed time
//  after an event Spaceman sees, lasts a fixed time and follows a fixed curve, so the labels replay
//  it from that event and move with the bar instead of waiting for the Dock to say where it went.
//  Swipes need none of this: the bar follows the fingers, then the Dock reports it as it finishes.
//
//  The curves come from 120fps recordings of macOS 26. The open and close timings were then fitted
//  with the debug motion recorder, to the native captions on macOS 26.7 over eight keyboard opens
//  and closes: within about a point once the timing for each one is known. What is left is when
//  Spaceman learns of each one: 5-8ms either way for an open, about 10ms for a close. Escape and
//  Ctrl+Up close on the same timing. Opening Mission Control as an app (its Dock icon, `open -a`)
//  runs about 14ms behind Ctrl+Up, and the window server's event doesn't say which it was.
//

import Foundation

enum DockMotion {

    /// A motion that starts `delay` after the event it is timed from and takes `duration`.
    struct Timing: Equatable {
        let delay: TimeInterval
        let duration: TimeInterval
        let curve: CubicBezier

        /// How far through the motion it is at `time`, eased, from 0 to 1, when timed from `reference`.
        func progress(at time: TimeInterval, from reference: TimeInterval) -> CGFloat {
            guard duration > 0 else { return 1 }
            return CGFloat(curve.value(at: (time - reference - delay) / duration))
        }

        func end(from reference: TimeInterval) -> TimeInterval {
            reference + delay + duration
        }

        /// How long after `reference` the motion first gets `fraction` of the way.
        func time(toReach fraction: CGFloat) -> TimeInterval {
            var low = 0.0
            var high = duration
            for _ in 0..<30 {
                let middle = (low + high) / 2
                if curve.value(at: middle / duration) < Double(fraction) { low = middle } else { high = middle }
            }
            return delay + (low + high) / 2
        }
    }

    /// Opening, timed from the window server's "Mission Control began" event.
    static let open = Timing(delay: 0.008, duration: 0.265, curve: CubicBezier(0.488, 0.040, 0.587, 1.003))
    /// Closing the bar of names, timed from the Dock reporting the bar gone or fully up.
    static let close = Timing(delay: 0.060, duration: 0.240, curve: CubicBezier(0.411, 0.457, 0.337, 1.132))
    /// Closing the bar of thumbnails, timed the same way. Not yet fitted on this Mac: it takes the
    /// close's correction to the delay.
    static let closeExpanded = Timing(delay: 0.060, duration: 0.236, curve: CubicBezier(0.436, 0.241, 0.514, 1.046))
    /// Closing the bar of thumbnails by a click off the bars, on a window or the desktop, timed from the click (its
    /// release, as Spaceman sees it). The Dock answers nothing for 100ms or so after such a click, so the close can't
    /// wait for its report, as the keyboard's does. Fitted on macOS 26.7 to two such closes with 15 desktops, filmed:
    /// to within 5pt of the captions' rise, 3pt on average; macOS's captions stay opaque as they go.
    static let clickClose = Timing(delay: 0.064, duration: 0.236, curve: CubicBezier(0.814, 0.835, 0.185, 0.884))
    /// Mission Control asked back while closing: the Dock turns the bar around from where it is.
    static let reverse = Timing(delay: 0.010, duration: 0.245, curve: CubicBezier(0.42, 0, 0.58, 1))
    /// The thumbnails of a hover-expanded bar sliding back to the middle once the pointer leaves them,
    /// timed from the Dock reporting them at their new places. Fitted on macOS 26.7 to slides of 87 and
    /// 303 points, filmed: the same timing whatever the distance, to within 2% of the travel.
    static let shift = Timing(delay: 0.040, duration: 0.220, curve: CubicBezier(0.0, 0.6, 0.6, 1.05))
    /// The bar of names growing into thumbnails, timed from the pointer entering it. Fitted on macOS
    /// 26.7 to three expansions, filmed: to within 2% of the travel, each starting 86-98ms after the
    /// pointer entered. Once, with the Dock still making its thumbnails, it started about 0.5s after.
    static let expand = Timing(delay: 0.092, duration: 0.200, curve: CubicBezier(0.1, 0.4, 0.6, 1.05))
    /// The captions riding that grow on a magnifying bar, from the names down to under the thumbnails, timed the
    /// same way: they start sooner and land sooner than the thumbnails finish, along and down alike. Fitted on macOS
    /// 26.7 to three expansions with 16 desktops, filmed: to within 4.5pt of the 112pt ride down, 2pt on average.
    static let growCaptions = Timing(delay: 0.044, duration: 0.197, curve: CubicBezier(0.778, 0.857, 0.59, 0.898))
    /// A desktop added in Mission Control: the thumbnails narrow and glide to make room, timed from the
    /// window server's "Mission Control began", which it sends for this too. Fitted on macOS 26.7 to
    /// two additions, filmed: to within 1% of the travel, both starting 23ms after the event.
    static let add = Timing(delay: 0.023, duration: 1.0, curve: CubicBezier(0.4, 0.0, 0.6, 1.05))
    /// A desktop removed in Mission Control: the others close the gap, timed the same way. Fitted to two
    /// removals, starting 89-98ms after the event.
    static let remove = Timing(delay: 0.093, duration: 0.200, curve: CubicBezier(0.1, 0.5, 0.3, 0.9))
    /// A desktop chosen by clicking its thumbnail: Mission Control closes into it, the bar sliding up,
    /// timed from the click. Fitted on macOS 26.7 to one click, filmed: to within 3% of the travel.
    static let choose = Timing(delay: 0.014, duration: 0.305, curve: CubicBezier(0.436, 0.241, 0.514, 1.046))
    /// A thumbnail moving aside, one place along, to make room for one dragged over its place. Fitted on
    /// macOS 26.7 to ten such moves, filmed at 60 frames a second, each from its own start: to within 2%
    /// of the travel.
    static let makeRoom = Timing(delay: 0, duration: 0.215, curve: CubicBezier(0.244, 0.674, 0.621, 1.0))
    /// Another desktop chosen by clicking its thumbnail: it zooms out of the thumbnail to fill the
    /// screen, over the bar, timed from the click. Fitted on macOS 26.7 to five zooms, filmed, from
    /// when each caption went under it: evenly over 0.2s, three starting 42-54ms after the click and
    /// two later, at 94 and 134ms, so this starts with the earlier ones.
    static let zoom = Timing(delay: 0.048, duration: 0.196, curve: CubicBezier(0, 0, 1, 1))

    /// A hover-expanded bar of thumbnails that don't magnify moves on timings of its own. Each was fitted on macOS
    /// 26.7 with 15 desktops on a 2560pt screen, filmed at 60 frames a second, and in a hand run at 30.
    enum Unmagnified {
        /// The Dock panning the bar sideways, as it does one too wide for the screen to bring the pointer's end
        /// into view, or back once the pointer leaves: timed from about when the Dock moved the thumbnails, as a
        /// reading first shows them at their new places. Fitted to five pans of 33-454pt: one timing whatever the
        /// distance, each pan starting within 3ms of the others, so within 3pt of the captions but for the first
        /// frame or two of the longest, up to 11pt.
        static let pan = Timing(delay: 0.011, duration: 0.234, curve: CubicBezier(0.224, 0.229, 0.264, 0.977))
        /// The captions riding the grow onto the bar, from the names down under the thumbnails, timed from the
        /// pointer entering it: along and down alike. macOS's ride starts about 30ms after, or, on some first
        /// expansions and those by hand, 13-21ms later and stuttering. Fitted to ten expansions of both kinds to keep
        /// the worst least: within 14pt of the 112pt ride down. Fitted to either kind alone, it would follow that
        /// within 5.5pt and miss the other by up to 26pt.
        static let ride = Timing(delay: 0.002, duration: 0.247, curve: CubicBezier(0.538, 0.036, 0.404, 0.714))
        /// Closing the bar from the keyboard, timed from about when the Dock moved it, as for `pan`. Fitted to
        /// three closes: to within 7pt of the captions' rise, but for one the Dock held back a frame, 11pt.
        static let close = Timing(delay: 0.042, duration: 0.250, curve: CubicBezier(0.579, 0.524, 0.363, 0.753))
        /// Closing the bar by a click off the bars, timed from the click, as `clickClose`. Fitted to five clicks
        /// sent by a script and two by hand: to within 4pt of the captions' rise for three, 9-13pt for two the
        /// Dock held back, 17-22pt for those by hand, whose closes ran sooner after the release the app sees.
        static let clickClose = Timing(delay: 0.032, duration: 0.220, curve: CubicBezier(0.677, 0.459, 0.396, 0.649))
    }
}

/// A replayed move of one label, as an offset in points from where it is placed (y down, as in
/// Accessibility): `from` at the start, nothing at the end.
struct TimedMove: Equatable {
    let timing: DockMotion.Timing
    let reference: TimeInterval
    let from: CGVector

    func isFinished(at time: TimeInterval) -> Bool {
        time >= timing.end(from: reference)
    }

    /// When the move starts (system uptime).
    var start: TimeInterval { reference + timing.delay }

    /// The offset at `time`.
    func offset(at time: TimeInterval) -> CGVector {
        let left = 1 - timing.progress(at: time, from: reference)
        return CGVector(dx: from.dx * left, dy: from.dy * left)
    }

    func earlier(by lead: TimeInterval) -> TimedMove {
        TimedMove(timing: timing, reference: reference - lead, from: from)
    }

    /// The offset at `steps + 1` evenly spaced moments from the move's start to its end.
    func keyframes(steps: Int) -> [CGVector] {
        (0...steps).map { step in
            let left = 1 - CGFloat(timing.curve.value(at: Double(step) / Double(steps)))
            return CGVector(dx: from.dx * left, dy: from.dy * left)
        }
    }
}

/// A replayed sideways slide of a bar's thumbnails, as an offset in points from where the Dock now
/// reports them: `from` at the start, 0 at the end.
struct TimedShift: Equatable {
    let timing: DockMotion.Timing
    let reference: TimeInterval
    let from: CGFloat

    func offset(at time: TimeInterval) -> CGFloat {
        from * (1 - timing.progress(at: time, from: reference))
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= timing.end(from: reference)
    }

    /// When the slide starts moving (system uptime).
    var start: TimeInterval { reference + timing.delay }

    func earlier(by lead: TimeInterval) -> TimedShift {
        TimedShift(timing: timing, reference: reference - lead, from: from)
    }

    /// The offset at `steps + 1` evenly spaced moments from the slide's start to its end.
    func keyframes(steps: Int) -> [CGFloat] {
        (0...steps).map { step in from * (1 - CGFloat(timing.curve.value(at: Double(step) / Double(steps)))) }
    }
}

/// A replayed slide of the bar, as a retraction: 0 with the bar in place, 1 with it off the screen.
struct TimedSlide: Equatable {
    let timing: DockMotion.Timing
    let reference: TimeInterval
    let from: CGFloat
    let to: CGFloat

    func retraction(at time: TimeInterval) -> CGFloat {
        from + (to - from) * timing.progress(at: time, from: reference)
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= timing.end(from: reference)
    }

    /// The same slide, `lead` seconds sooner.
    func earlier(by lead: TimeInterval) -> TimedSlide {
        TimedSlide(timing: timing, reference: reference - lead, from: from, to: to)
    }

    /// When the slide starts moving (system uptime).
    var start: TimeInterval { reference + timing.delay }

    /// The slide's retraction at `steps + 1` evenly spaced moments from its start to its end, for a
    /// keyframe animation.
    func keyframes(steps: Int) -> [CGFloat] {
        (0...steps).map { step in
            from + (to - from) * CGFloat(timing.curve.value(at: Double(step) / Double(steps)))
        }
    }
}

/// An easing curve from (0, 0) to (1, 1) with control points (x1, y1) and (x2, y2), as CSS's
/// cubic-bezier(). The y values may leave 0...1, for curves that overshoot and settle back.
struct CubicBezier: Equatable {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// The curve's height `x` of the way across: 0 before the start and 1 after the end.
    func value(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        return Self.coordinate(parameter(forX: x), c1: y1, c2: y2)
    }

    /// One coordinate at curve parameter `s`, for control-point coordinates `c1` and `c2`.
    private static func coordinate(_ s: Double, c1: Double, c2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * c1 + 3 * u * s * s * c2 + s * s * s
    }

    /// The parameter where the curve is `x` across, by bisection: with x1 and x2 in 0...1 the curve
    /// only ever moves right.
    private func parameter(forX x: Double) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if Self.coordinate(mid, c1: x1, c2: x2) < x { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}
