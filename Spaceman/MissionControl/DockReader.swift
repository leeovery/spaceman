//
//  DockReader.swift
//  Spaceman
//
//  Reads the Dock's Spaces Bars through Accessibility, off the main thread.
//

import AppKit
import ApplicationServices

/// Reads the Dock's Spaces Bars on a background queue. The main thread asks for a reading each
/// display frame and draws with the latest one it has, so a slow Dock delays the labels a little
/// but never stalls the drawing.
final class DockReader {

    struct Reading {
        var session = 0
        /// System uptime when read; 0 before the first reading of a session.
        var time: TimeInterval = 0
        /// When the Dock answered, which can be long after `time` while it is busy, as while it
        /// animates Mission Control open.
        var answered: TimeInterval = 0
        /// When the reading was asked for, for the debug recorder.
        var requested: TimeInterval = 0
        var layouts: [BarLayout] = []
        /// Counts the session's measurements, so a new one can be noticed.
        var layoutsVersion = 0
        /// The first bar's frame now, or nil when the Dock has no bar.
        var barFrame: CGRect?
        var mismatch: String?
        /// Each bar's selected thumbnail's place: the Dock's current space, which has its pill.
        var selected: [Int?] = []
    }

    private let queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).dockReader", qos: .userInteractive)
    private let condition = NSCondition()

    // Guarded by `condition`.
    private var reading = Reading()
    private var session = 0
    private var inFlight = false
    private var screens: [ScreenInfo] = []
    private var dockPID: pid_t = 0
    private var labelsUnnamed = false

    // Used only on `queue`.
    private var dock: (pid: pid_t, element: AXUIElement)?
    private var layouts: [BarLayout] = []
    private var layoutsVersion = 0
    private var mismatch: String?
    private var layoutsSession = -1
    private var lastMeasured: TimeInterval = 0
    /// Each followed bar's frame at the last reading, by its place among the bars, to tell it has come to rest.
    private var followedBarFrames: [Int: CGRect] = [:]
    /// Asked to measure everything at the next reading, whether due or not. Guarded by `condition`.
    private var measureRequested = false

    /// Starts a Mission Control session, forgetting the last one's readings. `labelsUnnamed` gives
    /// spaces never named a label too, as the session's style has it.
    func begin(dockPID: pid_t, screens: [ScreenInfo], labelsUnnamed: Bool) {
        condition.lock()
        session += 1
        reading = Reading(session: session)
        self.dockPID = dockPID
        self.screens = screens
        self.labelsUnnamed = labelsUnnamed
        condition.unlock()
    }

    func end() {
        condition.lock()
        session += 1
        reading = Reading(session: session)
        condition.unlock()
    }

    /// The latest reading, after waiting up to `timeout` for one under way to finish.
    func latest(waitingUpTo timeout: TimeInterval) -> Reading {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while inFlight {
            if !condition.wait(until: deadline) { break }
        }
        return reading
    }

    /// Measures everything at the next reading, as after desktops are reordered.
    func remeasureSoon() {
        condition.lock()
        measureRequested = true
        condition.unlock()
    }

    /// Asks for a fresh reading unless one is already under way; never waits. `remeasure` allows
    /// the periodic full measurement, which takes many more AX calls than following the bar. The
    /// thumbnails of bars `magnification` knows to magnify are followed as they resize.
    func request(remeasure: Bool, magnification: BarMagnification) {
        condition.lock()
        guard !inFlight else {
            condition.unlock()
            return
        }
        inFlight = true
        let force = measureRequested
        measureRequested = false
        let session = self.session
        let screens = self.screens
        let dockPID = self.dockPID
        let labelsUnnamed = self.labelsUnnamed
        condition.unlock()
        let requested = ProcessInfo.processInfo.systemUptime

        queue.async { [weak self] in
            guard let self else { return }
            var fresh = self.read(
                session: session, screens: screens, dockPID: dockPID, labelsUnnamed: labelsUnnamed,
                remeasure: remeasure, force: force, magnification: magnification)
            fresh.answered = ProcessInfo.processInfo.systemUptime
            fresh.requested = requested
            self.condition.lock()
            if fresh.session == self.session { self.reading = fresh }
            self.inFlight = false
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    private func read(
        session: Int, screens: [ScreenInfo], dockPID: pid_t, labelsUnnamed: Bool, remeasure: Bool,
        force: Bool, magnification: BarMagnification
    ) -> Reading {
        let now = ProcessInfo.processInfo.systemUptime
        if layoutsSession != session {
            layouts = []
            layoutsVersion = 0
            mismatch = nil
            layoutsSession = session
            lastMeasured = 0
            followedBarFrames = [:]
        }

        // Follow the bars measured already: the first bar's frame, and every thumbnail of a bar whose
        // thumbnails resize under the pointer, or else the first bar's first thumbnail to notice a shift.
        if let layout = layouts.first, let bar = layout.bar, let barFrame = AX.frame(of: bar) {
            let reshaped = abs(barFrame.width - layout.frame.width) > 0.5
                || abs(barFrame.height - layout.frame.height) > 0.5
            var shifted = false
            if !magnification.follows(layout), let button = layout.firstButton,
               let measuredX = layout.firstButtonX, let buttonX = AX.position(of: button)?.x {
                shifted = abs(buttonX - measuredX) > 0.5
                // The thumbnails sliding together, as the Dock moves them back to the middle: move the
                // layout with them rather than measure it all again, which takes many calls to a Dock
                // that is slow to answer as it starts the slide.
                let dx = buttonX - measuredX
                if shifted, !reshaped, let last = layout.lastButton, let lastX = layout.lastButtonX,
                   let lastNow = AX.position(of: last)?.x, abs((lastNow - lastX) - dx) <= 0.5 {
                    layouts[0] = layout.offsetBy(dx: dx)
                    layoutsVersion += 1
                    lastMeasured = now
                    return Reading(session: session, time: now, layouts: layouts, layoutsVersion: layoutsVersion,
                                   barFrame: barFrame, mismatch: mismatch, selected: selected())
                }
            }
            let due = force || remeasure && now - lastMeasured >= MissionControlLabels.measureInterval
            if !reshaped, !shifted, !due, followThumbnails(magnification, firstBarFrame: barFrame) {
                return Reading(session: session, time: now, layouts: layouts, layoutsVersion: layoutsVersion,
                               barFrame: barFrame, mismatch: mismatch, selected: selected())
            }
        }

        // No bar yet, the bar was replaced, or it changed: measure everything.
        mismatch = measure(screens: screens, dockPID: dockPID, labelsUnnamed: labelsUnnamed, now: now)
        layoutsVersion += 1
        return Reading(session: session, time: now, layouts: layouts, layoutsVersion: layoutsVersion,
                       barFrame: layouts.first?.frame, mismatch: mismatch, selected: selected())
    }

    /// Re-reads the thumbnails of each bar followed as they resize or slide under the pointer: a call for
    /// the list's count and one per thumbnail. Not while the bar itself is off its place, sliding in or out:
    /// the thumbnails move with it, which its frame tells, and taking their places too would move the labels
    /// twice. False, to measure everything, when they can't be read, their number changed, or the bar has
    /// come to rest off the place it was measured at.
    private func followThumbnails(_ magnification: BarMagnification, firstBarFrame: CGRect) -> Bool {
        var changed = false
        for (index, layout) in layouts.enumerated() where magnification.follows(layout) {
            guard let barFrame = index == 0 ? firstBarFrame : layout.bar.flatMap(AX.frame) else { continue }
            let before = followedBarFrames[index]
            followedBarFrames[index] = barFrame
            guard layout.isWhereMeasured(now: barFrame) else {
                if layout.restsOffItsPlace(now: barFrame, before: before) { return false }
                continue
            }
            guard let followed = layout.following(
                count: layout.list.flatMap(AX.childCount), frames: AX.frames(of: layout.buttons.map(\.element)))
            else { return false }
            guard followed.buttons.map(\.frame) != layout.buttons.map(\.frame) else { continue }
            layouts[index] = followed
            changed = true
        }
        if changed { layoutsVersion += 1 }
        return true
    }

    /// Each bar's selected thumbnail, as the Dock has it: it moves the pill the moment it changes,
    /// before macOS announces the new space.
    private func selected() -> [Int?] {
        layouts.map { layout in
            guard let list = layout.list, let chosen = AX.selectedChild(of: list) else { return nil }
            return layout.buttons.firstIndex { CFEqual($0.element, chosen) }
        }
    }

    /// Measures every Dock Spaces Bar and its captions: dozens of AX calls, so it runs when a bar
    /// appears or changes, and twice a second while it rests.
    private func measure(
        screens: [ScreenInfo], dockPID: pid_t, labelsUnnamed: Bool, now: TimeInterval
    ) -> String? {
        lastMeasured = now
        if dock?.pid != dockPID {
            let element = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(element, MissionControlLabels.axMessagingTimeout)
            dock = (dockPID, element)
        }
        guard let dock,
              let missionControl = AX.children(of: dock.element).first(where: {
                  AX.title(of: $0) == "Mission Control"
              })
        else {
            layouts = []
            return nil
        }
        var measured: [BarLayout] = []
        var mismatch: String?
        for bar in AX.spacesBars(in: missionControl, depthLimit: 3, matching: { AX.title(of: $0) == "Spaces Bar" }) {
            guard let barFrame = AX.frame(of: bar) else { continue }
            let foot = CGPoint(x: barFrame.midX, y: barFrame.maxY)
            guard let screen = screens.first(where: { $0.frame.contains(foot) }) else { continue }
            let list = AX.list(in: bar)
            let found = list?.buttons ?? []
            let result = MissionControlLabels.dockCaptions(found, screen: screen, labelsUnnamed: labelsUnnamed)
            mismatch = result.mismatch ?? mismatch
            measured.append(BarLayout(
                bar: bar,
                firstButton: found.first?.element,
                frame: barFrame,
                firstButtonX: found.first?.frame.minX,
                screen: screen.frame,
                displayID: screen.displayID,
                captions: result.captions,
                list: list?.element,
                buttons: found.map { ($0.element, $0.title, $0.frame) },
                spaceIDs: result.spaceIDs,
                lastButton: found.last?.element,
                lastButtonX: found.last?.frame.minX,
                addButton: AX.children(of: bar).first { AX.identifier(of: $0) == "mc.spaces.add" }
                    .flatMap(AX.frame)))
        }
        layouts = measured
        return mismatch
    }
}

// MARK: - AX helpers

/// Stateless Accessibility reads, safe from any thread.
enum AX {

    typealias Button = (element: AXUIElement, frame: CGRect, title: String)

    static func spacesBars(in root: AXUIElement, depthLimit: Int,
                           matching isBar: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= depthLimit else { return }
            for child in children(of: element) {
                if isBar(child) { found.append(child); continue }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return found
    }

    static func buttons(in bar: AXUIElement) -> [Button] {
        list(in: bar)?.buttons ?? []
    }

    /// The bar's list of thumbnails, and its buttons.
    static func list(in bar: AXUIElement) -> (element: AXUIElement, buttons: [Button])? {
        for list in children(of: bar) {
            let found = children(of: list).compactMap { button -> Button? in
                guard let buttonFrame = frame(of: button) else { return nil }
                return (button, buttonFrame, title(of: button) ?? "")
            }
            if !found.isEmpty { return (list, found) }
        }
        return nil
    }

    static func selectedChild(of list: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            list, kAXSelectedChildrenAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? [AXUIElement])?.first
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func identifier(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXIdentifierAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func childCount(of element: AXUIElement) -> Int? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success
        else { return nil }
        return count
    }

    /// Each element's frame, its position and size read in one call; nil if any can't be read.
    static func frames(of elements: [AXUIElement]) -> [CGRect]? {
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var frames: [CGRect] = []
        frames.reserveCapacity(elements.count)
        for element in elements {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(
                element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let pair = values as? [AnyObject], pair.count == 2,
                  let position = value(pair[0], .cgPoint, as: CGPoint.zero),
                  let size = value(pair[1], .cgSize, as: CGSize.zero), size.width > 0, size.height > 0
            else { return nil }
            frames.append(CGRect(origin: position, size: size))
        }
        return frames
    }

    /// `object` as an AX value of `type`; nil for anything else, such as the error a failed read gives.
    private static func value<Value>(_ object: AnyObject, _ type: AXValueType, as empty: Value) -> Value? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let axValue = object as! AXValue  // swiftlint:disable:this force_cast
        var result = empty
        return AXValueGetType(axValue) == type && AXValueGetValue(axValue, type, &result) ? result : nil
    }

    static func position(of element: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        return position
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}
