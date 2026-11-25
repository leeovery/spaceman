//
//  MissionControlSwipeTracker.swift
//  Spaceman
//
//  Follows the trackpad's vertical three-finger swipe, which opens and closes Mission Control.
//
//  The Dock receives the swipe as dock-control events (CGEvent type 30, IOHID type 23, "dock
//  swipe"), whose undocumented fields carry its motion, phase and progress; GestureSwitcher posts
//  events with the same fields. Progress runs from 0 towards -1 as a swipe up opens Mission
//  Control and from 0 towards 1 as a swipe down closes it, and the Dock moves the Spaces Bar in
//  proportion: at progress 0.5 the bar is halfway off its screen (measured on macOS 26.7). The
//  trackpad reports progress about 60 times a second as a fraction, while the Dock reports the
//  bar's position less often and in whole points, so following the progress moves the labels
//  smoothly while the fingers are down.
//

import AppKit
import os

final class MissionControlSwipeTracker {

    enum State: Equatable {
        case idle
        /// Fingers down, with the Spaces Bar `retraction` of the way off its screen.
        case swiping(retraction: CGFloat)
        /// Fingers lifted at `time` (system uptime) with the bar at `retraction`, last moving in
        /// `direction`: 1 sliding off the screen, -1 sliding on, 0 still; at `velocity` bar heights per
        /// second, positive sliding off.
        case released(time: TimeInterval, retraction: CGFloat, direction: CGFloat, velocity: Double)
    }

    private(set) var state: State = .idle
    /// Counts swipes, so a swipe the Dock has been seen to act on can be told from the next.
    private(set) var gesture = 0
    /// The bar's retraction as the current swipe started.
    private(set) var gestureStart: CGFloat = 1
    /// When the current swipe began (system uptime), and whether the fingers are still down.
    private(set) var gestureBeganAt: TimeInterval = 0
    private(set) var isGestureActive = false

    /// Called on the main thread whenever a swipe moves or ends.
    var onSwipe: (() -> Void)?
    /// Called on the main thread where a click lets go, in AX coordinates: origin at the top-left of
    /// the primary display, y down. A press that moved further than `clickSlop`, a drag, is no click.
    var onClick: ((CGPoint) -> Void)?
    /// A press that moved, as when a thumbnail is dragged in Mission Control, let go at the point.
    var onDrop: ((CGPoint) -> Void)?
    /// Where the left button went down, while it is down.
    private(set) var pressedAt: CGPoint?
    private static let clickSlop: CGFloat = 4

    /// The bar's retraction as a swipe starts: 0 while Mission Control is open, 1 while closed.
    var currentRetraction: () -> CGFloat = { 1 }

    private static let log = Logger(subsystem: Constants.AppInfo.bundleId, category: "missionControlSwipe")

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var startRetraction: CGFloat?
    private var lastRetraction: CGFloat?
    private var direction: CGFloat = 0
    /// The latest few positions (system uptime, retraction), for the speed the fingers lift at.
    private var samples: [(time: TimeInterval, retraction: CGFloat)] = []
    /// How far back the lifting speed is measured over.
    private static let velocityWindow: TimeInterval = 0.05
    /// Whether this swipe moves the Spaces Bar, decided by which way it first moves.
    private var drivesBar: Bool?
    /// Progress a swipe must make before its first direction counts.
    private static let directionThreshold: CGFloat = 0.01

    // CGEventField(rawValue:) is optional due to RawRepresentable, but it wraps
    // any UInt32 without validation — these will never return nil.
    // swiftlint:disable force_unwrapping
    private static let hidType = CGEventField(rawValue: 110)!
    private static let swipeMotion = CGEventField(rawValue: 123)!
    private static let swipeProgress = CGEventField(rawValue: 124)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    // swiftlint:enable force_unwrapping

    private static let dockControlType: UInt32 = 30
    private static let hidDockSwipe: Int64 = 23
    private static let motionVertical: Int64 = 2
    private static let phaseBegan: Int64 = 1
    private static let phaseChanged: Int64 = 2
    private static let phaseEnded: Int64 = 4
    private static let phaseCancelled: Int64 = 8

    /// The bar's retraction during a swipe that started at retraction `start` and has reached
    /// `progress`.
    static func retraction(start: CGFloat, progress: CGFloat) -> CGFloat {
        min(max(start + progress, 0), 1)
    }

    /// Whether a swipe that started at retraction `start` and first moved to `progress` moves the
    /// bar. The Dock settles what a swipe does by its first movement: up while Mission Control is open
    /// only pushes the windows back, and down while it is closed is App Exposé, so pulling the other
    /// way later in the same swipe moves no bar either.
    static func drivesBar(start: CGFloat, progress: CGFloat) -> Bool {
        start < 0.5 ? progress > 0 : progress < 0
    }

    /// Listens for swipes. Needs the Accessibility permission Spaceman already has; without it the
    /// tap cannot be created and the labels follow the Dock's reports alone.
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(Self.dockControlType)
            | CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1) << CGEventMask(CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<MissionControlSwipeTracker>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                        .handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Self.log.log("Could not listen for trackpad swipes")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        settle()
    }

    /// Forgets a finished swipe once the Dock's own reports have taken over.
    func settle() {
        state = .idle
        startRetraction = nil
        lastRetraction = nil
        direction = 0
        drivesBar = nil
        samples = []
        isGestureActive = false
    }

    /// Bar heights per second over the last `velocityWindow`, positive sliding off the screen.
    static func velocity(of samples: [(time: TimeInterval, retraction: CGFloat)]) -> Double {
        guard let last = samples.last,
              let first = samples.last(where: { last.time - $0.time >= velocityWindow }) ?? samples.first,
              last.time - first.time > 0.005
        else { return 0 }
        return Double(last.retraction - first.retraction) / (last.time - first.time)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .leftMouseDown {
            pressedAt = event.location
            return
        }
        if type == .leftMouseUp {
            let place = event.location
            if let pressed = pressedAt {
                if hypot(place.x - pressed.x, place.y - pressed.y) <= Self.clickSlop {
                    onClick?(place)
                } else {
                    onDrop?(place)
                }
            }
            pressedAt = nil
            return
        }
        guard type.rawValue == Self.dockControlType,
              event.getIntegerValueField(Self.hidType) == Self.hidDockSwipe,
              event.getIntegerValueField(Self.swipeMotion) == Self.motionVertical
        else { return }

        let progress = CGFloat(event.getDoubleValueField(Self.swipeProgress))
        switch event.getIntegerValueField(Self.gesturePhase) {
        case Self.phaseBegan:
            startRetraction = currentRetraction()
            gesture += 1
            gestureStart = startRetraction ?? 1
            gestureBeganAt = ProcessInfo.processInfo.systemUptime
            isGestureActive = true
            lastRetraction = nil
            direction = 0
            drivesBar = nil
            samples = []
        case Self.phaseChanged:
            let start = startRetraction ?? currentRetraction()
            startRetraction = start
            if drivesBar == nil, abs(progress) > Self.directionThreshold {
                drivesBar = Self.drivesBar(start: start, progress: progress)
            }
            guard drivesBar == true else { return }
            move(to: Self.retraction(start: start, progress: progress))
            state = .swiping(retraction: lastRetraction ?? start)
            onSwipe?()
        case Self.phaseEnded, Self.phaseCancelled:
            isGestureActive = false
            // A swipe with no movement, such as a burst of synthetic events, moved nothing.
            guard drivesBar == true, let start = startRetraction, lastRetraction != nil else {
                settle()
                return
            }
            move(to: Self.retraction(start: start, progress: progress))
            state = .released(
                time: ProcessInfo.processInfo.systemUptime,
                retraction: lastRetraction ?? start,
                direction: direction,
                velocity: Self.velocity(of: samples))
            startRetraction = nil
            lastRetraction = nil
            direction = 0
            onSwipe?()
        default:
            break
        }
    }

    private func move(to retraction: CGFloat) {
        if let last = lastRetraction, retraction != last {
            direction = retraction > last ? 1 : -1
        }
        lastRetraction = retraction
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, retraction))
        samples.removeAll { now - $0.time > Self.velocityWindow * 3 }
    }
}
