//
//  MissionControlLabels.swift
//  Spaceman
//
//  Draws the user's space names over Mission Control's "Desktop 1", "Desktop 2"
//  captions.
//
//  Adapted from ActiveSpace (github.com/PerpetualBeta/ActiveSpace) with permission.
//  ActiveSpace itself credits MacSpaceLabeler (github.com/JohnSparham/MacSpaceLabeler)
//  for showing this approach on macOS 26.
//
//  On macOS 27+ the Spaces Bar lives in WindowManager (com.apple.WindowManager):
//
//      AXApplication "WindowManager"
//        AXGroup id=mc.display              one per display
//          AXGroup "Spaces Bar" id=mc.spaces
//            AXList id=mc.spaces.list
//              AXButton "Desktop 1" desc="exit to Desktop 1"   one per space
//
//  The Dock path is kept for macOS 26 and earlier. There the labels follow the Spaces Bar as it
//  slides: the trackpad's swipe progress while the fingers are down, then the Dock's own reports
//  of the bar's position. The Dock is read on a background queue, so drawing, once per display
//  frame, never waits on it, even when a busy Dock answers slowly.
//

import AppKit
import ApplicationServices
import os

final class MissionControlLabels {

    static let log = Logger(
        subsystem: Constants.AppInfo.bundleId, category: "missionControlLabels")

    private var timer: Timer?
    private var apps: [String: (pid: pid_t, element: AXUIElement)] = [:]
    let overlay = MissionControlLabelOverlay()
    let swipe = MissionControlSwipeTracker()
    let reader = DockReader()
    lazy var clock = FrameClock { [weak self] in self?.tick() }

    /// macOS 27 moved the Spaces Bar to WindowManager and left the Dock an empty stub.
    static let spacesBarIsInDock =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    private var lastMismatch: String?
    private var lastOutcome: String?
    private var showingWindowManagerLabels = false

    // Dock tracking: from when Mission Control appears until it is gone, the labels are drawn every
    // display frame, moved with the Spaces Bar.
    var isTracking = false
    private var trackingStarted: TimeInterval = 0
    /// The last session's bars, moved to rest, for a swipe that starts before the Dock reports
    /// the bar.
    var restingLayouts: [BarLayout] = []
    /// The Dock reader's measurement last seen, to notice a new one.
    var layoutsVersion = 0
    /// The bar's retraction as last drawn.
    var retraction: CGFloat = 1
    /// The last swipe the Dock was seen to act on.
    var confirmedGesture: Int?
    /// A motion of the bar the Dock reports only the end of, being replayed: opening and closing from
    /// the keyboard, a hot corner or a click.
    var slide: TimedSlide?
    /// When the window server last said Mission Control was starting (system uptime).
    var missionControlBeganAt: TimeInterval?
    /// Whether the window server's Mission Control events reach Spaceman.
    var seesMissionControlBegin = false
    var registeredWindowServerEvents = false
    /// Whether the Dock has reported a bar this session.
    private var sawBar = false
    /// When the Dock reader's latest reading, and the one before it, were taken.
    private var latestReadingTime: TimeInterval = 0
    private var previousReadingTime: TimeInterval = 0
    var lastSwipeRecord: String?
    var lastPointerRecord: CGPoint?
    /// The layouts last drawn from the Dock, to notice the hover-expanded thumbnails sliding sideways.
    private var shownLayouts: [BarLayout] = []
    /// The first bar's thumbnails sliding sideways, which the Dock reports only the end of.
    var shift: (screen: CGRect, slide: TimedShift)?
    /// The bar of names growing into thumbnails, which the Dock reports only once it is well under way:
    /// replayed from the pointer entering the bar, `from` its names `to` the thumbnails' places.
    var grow: (screen: CGRect, reference: TimeInterval, from: BarLayout, to: BarLayout)?
    /// The pointer has entered a bar of names, and the Dock is about to grow it.
    var pendingGrow: (time: TimeInterval, bar: BarLayout)?
    /// Each display's thumbnails as the Dock last laid them out, moved to the middle of the screen.
    private var expandedLayouts: [CGDirectDisplayID: BarLayout] = [:]
    /// The same, by display and number of thumbnails, to know where they go as a desktop comes or goes.
    var expandedLayoutsByCount: [String: BarLayout] = [:]
    /// When the window server last said Mission Control was starting while it was already open, as it
    /// does as a desktop is added or removed.
    var spaceChangeBeganAt: TimeInterval?
    /// A click that adds or removes a desktop, which the window server's event then confirms.
    var pendingChange: (change: DesktopChange, time: TimeInterval)?
    /// A thumbnail being dragged to another place.
    var drag: ThumbnailDrag?
    /// Mission Control's own captions, watched while a thumbnail is dragged.
    var captionWatcher: MissionControlCaptionWatcher?
    /// When the last frame of them taken in was shown.
    var lastWatchedFrame: TimeInterval = 0
    /// For the debug recording: the space whose thumbnail was last dropped, and when it settled.
    var droppedSpace: (spaceID: String, time: TimeInterval)?
    /// For the debug recording: what was last noted of a drag's label.
    var lastDragTrace: String?
    /// Whether the labels have been kept to the desktop Mission Control opened on. macOS draws the
    /// windows of every desktop into the zoom to a desktop chosen by its thumbnail, at the click: a tap
    /// gives no warning, so they are kept to this one from when the bar is in.
    private var keptToThisDesktop = false
    /// Another desktop chosen by clicking its thumbnail, `from` where it zooms out to fill the screen.
    var zoom: (screen: CGRect, from: CGRect, reference: TimeInterval)?
    /// How far that desktop has zoomed over its screen, for this frame.
    var zoomCover: CGRect?
    /// A desktop added or removed: the labels move from where each space's thumbnail was, on the Dock's
    /// timing, to where the Dock puts it.
    var reflow: Reflow?
    /// The pointer's last place, in Accessibility coordinates, and when it moved there.
    private var pointer: (time: TimeInterval, point: CGPoint)?
    /// When the window server last said Mission Control had finished closing (system uptime).
    var missionControlEndedAt: TimeInterval?

    // Native look: labels drawn to match the captions they cover, from a capture of the bar at rest.
    /// Looks by caption, kept across sessions so a label slides in matched from its first frame.
    var captionLooks = CaptionLooks()
    /// The bars as last seen at rest, and since when, so a capture waits for them to settle.
    var restingSignature: String?
    var restingSince: TimeInterval = 0
    /// The bars this session last captured, and whether a capture is under way.
    var capturedSignature: String?
    var isCapturing = false
    /// Counts frames that found the bars moving, or not fully in, so a capture can tell whether
    /// anything moved while it ran.
    var motionCount = 0
    /// Captures this session by the bars' signature, so captures that never agree stop retrying.
    var captureAttempts: [String: Int] = [:]
    /// The style this session's labels are drawn in, fixed at its start so a session never mixes them.
    var labelStyle = MissionControlLabelStyle.spaceColors
    var requestedCaptureAccess = false
    /// Each display's current space, whose caption Mission Control puts in a pill.
    var currentSpaceIDs: Set<String> = []
    /// While debugging, the last trace of where the labels went, to log only changes.
    var lastTrace: String?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: MissionControlLabelStyle.namesShownKey)
    }

    /// How often to look for Mission Control while it is closed (default 50ms). A trackpad swipe
    /// is noticed at once without it; this catches the keyboard, hot corners and the Dock. Once
    /// Mission Control is open the labels follow the display's refresh instead.
    private static var pollInterval: TimeInterval {
        let pollMs = UserDefaults.standard.object(forKey: "missionControlPollMs") as? Int ?? 50
        return TimeInterval(max(16, pollMs)) / 1000
    }

    /// Re-measure the bars this often while the bar rests, for reorders and renames.
    static let measureInterval: TimeInterval = 0.5

    /// For this long after the fingers lift, the labels do not move back against the swipe while
    /// the Dock's reports, a few milliseconds behind the trackpad, catch up.
    static let handOffWindow: TimeInterval = 0.06

    /// How long after the fingers lift to keep waiting for the Dock to report the bar.
    private static let releaseGrace: TimeInterval = 0.4

    /// How long to wait for the Dock to report a bar once Mission Control has appeared.
    private static let appearGrace: TimeInterval = 0.3

    /// How often to look for Mission Control when the window server announces it: a safety net.
    private static let eventBackedPollInterval: TimeInterval = 1

    /// How long after a replayed open ends to hold the labels in place for the Dock's first answer.
    private static let openAnswerLimit: TimeInterval = 0.3

    /// How far off rest, as a fraction of the bar's height, still counts as at rest.
    private static let restSlack: CGFloat = 0.05

    /// Bars taller than this show thumbnails.
    static let expandedBarHeight: CGFloat = 60
    /// How long a replayed growth waits for the Dock to report the thumbnails before giving up on it.
    private static let growAnswerLimit: TimeInterval = 1.0

    /// How long a display frame waits for the Dock reader before drawing with an older reading.
    private static let readingWait: TimeInterval = 0.004

    /// Fraction of interval the poll may be late.
    private static let pollToleranceFraction = 0.2

    /// Timeout for AX calls, so a busy or hung process cannot stall Spaceman for long.
    static let axMessagingTimeout: Float = 0.1

    /// Gap between neighbouring labels.
    static let labelGap: CGFloat = 4

    init() {
        // Measure the label font here, on the main thread, before the Dock reader needs it.
        _ = MissionControlLabelOverlay.labelHeight

        // Listen for app terminations to clear cached AX elements
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.apps = self?.apps.filter { $0.value.pid != app.processIdentifier } ?? [:]
        }

        // Listen for preference changes (only .standard, not other suites)
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.handlePreferenceChange()
        }

        // After sleep/wake or lock/unlock the cached AX elements and label windows can stop
        // working while the processes are still alive. Only a fresh start recovered them, so
        // discard them and let the next poll recreate everything.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reset(reason: "wake")
        }
        workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reset(reason: "session active")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.reset(reason: "screen unlocked")
        }
        // Label windows and measured positions belong to the screens as they were.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reset(reason: "screens changed")
        }

        // Switching spaces with Mission Control open moves the pill to the new space's caption, and the
        // labels, kept to the desktop they opened on, move to the new one.
        workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.currentSpaceIDs = Self.currentSpaceIDs()
            if self.isTracking, self.keptToThisDesktop, self.zoom == nil {
                self.overlay.showOnEveryDesktop(true)
                self.keptToThisDesktop = false
            }
        }

        swipe.currentRetraction = { [weak self] in
            guard let self, self.isTracking else { return 1 }
            return self.retraction
        }
        swipe.onSwipe = { [weak self] in self?.beginTracking() }
        swipe.onClick = { [weak self] point in self?.handleClick(at: point) }
        swipe.onDrop = { [weak self] point in self?.handleDrop(at: point) }

        // Start if already enabled
        if isEnabled {
            start()
        }
    }

    private func handlePreferenceChange() {
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard timer == nil else { return }
        if Self.spacesBarIsInDock { observeWindowServer() }
        let interval = seesMissionControlBegin ? Self.eventBackedPollInterval : Self.pollInterval
        let pollTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        pollTimer.tolerance = interval * Self.pollToleranceFraction
        RunLoop.main.add(pollTimer, forMode: .common)
        timer = pollTimer
        if Self.spacesBarIsInDock { swipe.start() }
        requestCaptureAccessIfNeeded()
        MissionControlMotionRecorder.shared.start()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        swipe.stop()
        MissionControlMotionRecorder.shared.stop()
        reset(reason: "disabled")
    }

    /// Drops cached AX elements, measurements and label windows, so the next poll starts as fresh
    /// as an app restart.
    private func reset(reason: String) {
        Self.log.log("Reset (\(reason, privacy: .public))")
        endTracking()
        overlay.close()
        apps = [:]
        restingLayouts = []
        showingWindowManagerLabels = false
        lastMismatch = nil
        lastOutcome = nil
        // An event tap can stop delivering after sleep; listen afresh.
        if timer != nil, Self.spacesBarIsInDock {
            swipe.stop()
            swipe.start()
        }
    }

    /// Logs the outcome only when it changes, to avoid flooding the log on every frame.
    private func logOutcome(_ outcome: String) {
        guard outcome != lastOutcome else { return }
        lastOutcome = outcome
        Self.log.log("\(outcome, privacy: .public)")
    }

    func logMismatch(_ message: String?) {
        guard let message, message != lastMismatch else { return }
        lastMismatch = message
        Self.log.log("Mismatch: \(message, privacy: .public)")
    }

    // MARK: - Poll

    /// Looks for Mission Control while it is closed. The Dock's bar starts tracking, which then
    /// runs every display frame until the bar is gone; WindowManager's bar is drawn here.
    private func poll() {
        guard AXIsProcessTrusted() else {
            logOutcome("Not trusted for Accessibility")
            endTracking()
            overlay.hide()
            return
        }
        guard !isTracking else { return }
        // Listening for swipes needs Accessibility, which may have been granted since launch.
        if Self.spacesBarIsInDock { swipe.start() }

        // macOS 27+: WindowManager. macOS 26.7's WindowManager shows the Spaces Bar too, at its resting place
        // from the first moment of a swipe, so on 26 the Dock alone is followed.
        if !Self.spacesBarIsInDock, let windowManager = appElement("com.apple.WindowManager") {
            let bars = AX.spacesBars(in: windowManager, depthLimit: 2) {
                AX.identifier(of: $0) == "mc.spaces"
            }
            if !bars.isEmpty {
                if !showingWindowManagerLabels { lastMismatch = nil }
                let screens = ScreenInfo.current()
                let mirror = bars.count == 1 && screens.count > 1 && Self.displaysShareSpaces()
                var labels: [MissionControlLabel] = []
                for bar in bars {
                    for caption in windowManagerCaptions(in: bar, mirrorToOtherScreens: mirror, screens: screens) {
                        guard let screen = screens.first(where: { $0.frame.contains(caption.centre) }) ?? screens.first
                        else { continue }
                        labels.append(
                            Self.label(for: caption, centre: caption.centre, screen: screen.frame, look: nil))
                    }
                }
                logOutcome("Spaces Bar found, \(labels.count) labels shown")
                overlay.render(labels)
                showingWindowManagerLabels = true
                return
            }
        }
        if showingWindowManagerLabels {
            showingWindowManagerLabels = false
            overlay.hide()
        }

        // Dock (macOS 26 and earlier)
        if Self.spacesBarIsInDock, let dock = appElement("com.apple.dock"),
           AX.children(of: dock).contains(where: { AX.title(of: $0) == "Mission Control" }) {
            beginTracking()
        } else {
            logOutcome("Spaces Bar not found")
        }
    }

    // MARK: - Dock tracking

    func beginTracking() {
        guard !isTracking, Self.spacesBarIsInDock, AXIsProcessTrusted(),
              appElement("com.apple.dock") != nil, let pid = apps["com.apple.dock"]?.pid
        else { return }
        isTracking = true
        trackingStarted = ProcessInfo.processInfo.systemUptime
        beginLookSession()
        sawBar = false
        latestReadingTime = 0
        previousReadingTime = 0
        currentSpaceIDs = Self.currentSpaceIDs()
        lastMismatch = nil
        layoutsVersion = 0
        reader.begin(dockPID: pid, screens: ScreenInfo.current(), labelsUnnamed: labelStyle == .spaceColors)
        pointer = (trackingStarted, Self.axPoint(NSEvent.mouseLocation))
        clock.start()
        tick()
    }

    static func axPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    /// Where the pointer is, each frame: global event monitors hear nothing while Mission Control is up.
    private func followPointer(at time: TimeInterval) {
        let point = Self.axPoint(NSEvent.mouseLocation)
        guard point != pointer?.point else { return }
        if drag != nil, swipe.pressedAt != nil {
            dragMoved(to: point, at: time)
            pointer = (time, point)
        } else {
            pointerMoved(to: point, at: time)
        }
    }

    /// The pointer entering a bar of names at rest: the Dock grows it into thumbnails a moment later.
    private func pointerMoved(to point: CGPoint, at time: TimeInterval) {
        guard isTracking else { return }
        let wasIn = pointer.map { last in restingLayouts.contains { $0.frame.contains(last.point) } } ?? true
        pointer = (time, point)
        guard !wasIn, grow == nil, pendingGrow == nil, retraction <= Self.restSlack, slide == nil,
              swipe.state == .idle,
              let bar = restingLayouts.first(where: { $0.frame.contains(point) }),
              bar.frame.height <= Self.expandedBarHeight
        else { return }
        pendingGrow = (time, bar)
        record(String(format: "pointer into the bar at x %.0f", point.x), at: time)
    }

    /// Replays the bar growing, just before the Dock starts it, if the pointer is still in the bar and
    /// an earlier expansion showed where the thumbnails go: the hovered desktop's under the pointer,
    /// or all of them in the middle when the pointer is past the names.
    private func startGrowIfDue(_ pending: (time: TimeInterval, bar: BarLayout), reading: DockReader.Reading,
                                frameTime: TimeInterval) {
        guard frameTime + clock.frameDuration >= pending.time + DockMotion.expand.delay else { return }
        pendingGrow = nil
        let bar = pending.bar
        guard let point = pointer?.point, bar.frame.contains(point), slide == nil else { return }
        var to: BarLayout
        if let reported = reading.layouts.first(where: {
            $0.screen == bar.screen && $0.frame.height > Self.expandedBarHeight
        }) {
            to = reported.atRest()
        } else {
            guard let layout = expandedLayouts[bar.displayID],
                  layout.captions.map(\.covers) == bar.captions.map(\.covers)
            else { return }
            let hovered = bar.buttons.first { $0.frame.minX <= point.x && point.x <= $0.frame.maxX }
            let dx = hovered.flatMap { button in layout.buttons.first { $0.title == button.title } }
                .map { point.x - $0.frame.midX } ?? 0
            to = layout.offsetBy(dx: dx)
        }
        // The names as they are now, at the thumbnails' places.
        to.captions = to.captions.map { caption in
            guard let now = bar.captions.first(where: { $0.covers == caption.covers }) else { return caption }
            return Caption(centre: caption.centre, maxWidth: caption.maxWidth, covers: caption.covers,
                           name: now.name, colorHex: now.colorHex, spaceID: now.spaceID)
        }
        grow = (bar.screen, pending.time, bar, to)
        record("grow", at: pending.time + DockMotion.expand.delay)
    }

    /// A replayed growth is over once it has run and the Dock reports the thumbnails, or once the
    /// Dock has taken too long to.
    private func growIsOver(_ running: (screen: CGRect, reference: TimeInterval, from: BarLayout, to: BarLayout),
                            reading: DockReader.Reading, frameTime: TimeInterval) -> Bool {
        let reported = reading.layouts.contains {
            $0.screen == running.screen && $0.frame.height > Self.expandedBarHeight
        }
        if reported, frameTime >= DockMotion.expand.end(from: running.reference) { return true }
        return frameTime >= running.reference + Self.growAnswerLimit
    }

    func endTracking() {
        guard isTracking else { return }
        isTracking = false
        slide = nil
        shift = nil
        grow = nil
        pendingGrow = nil
        reflow = nil
        spaceChangeBeganAt = nil
        pendingChange = nil
        drag = nil
        stopWatching()
        zoom = nil
        zoomCover = nil
        droppedSpace = nil
        if keptToThisDesktop { overlay.showOnEveryDesktop(true) }
        keptToThisDesktop = false
        pointer = nil
        shownLayouts = []
        sawBar = false
        if MissionControlMotionRecorder.isEnabled {
            MissionControlMotionRecorder.shared.refreshOwnWindows()
        }
        clock.stop()
        reader.end()
        overlay.hide()
        recordDrawn(at: ProcessInfo.processInfo.systemUptime)
        retraction = 1
        swipe.settle()
        logOutcome("Spaces Bar not found")
    }

    /// Where the labels go on a frame.
    private enum Placement {
        case at(CGFloat)
        /// Replaying a slide on the Dock's timing, which the render server runs.
        case slide(TimedSlide)
        /// Nowhere for now, while tracking carries on.
        case hidden
        /// Mission Control has gone.
        case gone
    }

    /// Runs every display frame while Mission Control is open or a swipe is moving: works out how
    /// far the Spaces Bar is off its screen and draws the labels there. It only reads what the
    /// Dock reader last learned, and asks it for more, so it never waits on the Dock.
    private func tick() {
        guard isTracking else { return }
        // A frame that doesn't find the bars fully in and still counts as motion for the capture.
        var resting = false
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            if !resting { noteMotion() }
            captionLooks.noteBars(resting: resting, at: now)
        }
        // Replayed slides are worked out for when this frame reaches the screen.
        let frameTime = max(clock.targetTime ?? now, now)
        if let running = shift, running.slide.isFinished(at: frameTime) { shift = nil }
        recordPointer()
        followPointer(at: now)
        // Re-measure only while nothing moves, so a measurement never holds up a slide.
        reader.request(remeasure: retraction <= 0 && swipe.state == .idle && slide == nil)
        // A reading usually takes about a millisecond: wait briefly for this frame's, so the labels
        // stay in step with the Dock, but draw with the last one rather than wait on a busy Dock.
        // A replayed slide doesn't need it, so it never waits.
        let reading = reader.latest(waitingUpTo: slide == nil ? Self.readingWait : 0)
        take(reading)
        watchCaptions(frameTime: frameTime)
        if let pending = pendingGrow { startGrowIfDue(pending, reading: reading, frameTime: frameTime) }
        if let running = grow, growIsOver(running, reading: reading, frameTime: frameTime) { grow = nil }
        // A predicted move waits a little for the Dock to report where the thumbnails went.
        if let running = reflow, frameTime >= running.timing.end(from: running.reference)
            + (running.predicted == nil ? 0 : Self.growAnswerLimit) {
            reflow = nil
        }
        if slide != nil {
            grow = nil
            pendingGrow = nil
        }

        let layouts = reading.layouts
        if let running = zoom {
            // Gone once the chosen desktop fills the screen; until then the bar stays where it is.
            guard frameTime < DockMotion.zoom.end(from: running.reference) else {
                endTracking()
                return
            }
            let progress = DockMotion.zoom.progress(at: frameTime, from: running.reference)
            zoomCover = Self.interpolate(running.from, running.screen, progress)
            place(at: 0, slide: nil, reading: reading, frameTime: frameTime)
            return
        }
        let dock: CGFloat? = reading.barFrame.flatMap { barFrame in
            layouts.first.map { Self.retraction(bar: barFrame, screen: $0.screen) }
        }
        if dock != nil { sawBar = true }
        if swipe.gesture != confirmedGesture, swipe.state != .idle, dockTookSwipe(dock: dock) {
            confirmedGesture = swipe.gesture
        }
        recordSwipe()

        switch placement(reading: reading, dock: dock, now: now, frameTime: frameTime) {
        case .hidden:
            overlay.hide()
            recordDrawn(at: frameTime)
        case .gone:
            endTracking()
        case .slide(let timed):
            // The window server shows the slide as at the frame's time or one frame before: started half a
            // frame early, it is never more than half a frame off.
            place(at: timed.retraction(at: frameTime), slide: timed.earlier(by: clock.frameDuration / 2),
                  reading: reading, frameTime: frameTime)
        case .at(let current):
            place(at: current, slide: nil, reading: reading, frameTime: frameTime)
            if current <= 0, !keptToThisDesktop, overlay.isShowing {
                keptToThisDesktop = true
                overlay.showOnEveryDesktop(false)
            }
            if current <= 0, swipe.state == .idle, slide == nil, shift == nil, grow == nil, pendingGrow == nil,
               reflow == nil, drag == nil, swipe.pressedAt == nil, !layouts.isEmpty {
                resting = true
                captureIfSettled(layouts, now: now)
            }
        }
    }

    func place(at current: CGFloat, slide: TimedSlide?, reading: DockReader.Reading, frameTime: TimeInterval) {
        retraction = current
        if reading.layouts.isEmpty {
            draw(restingLayouts, retraction: current, selected: [], slide: slide, at: frameTime)
        } else {
            draw(reading.layouts, retraction: current, selected: reading.selected, slide: slide, at: frameTime)
        }
        record(String(format: "drawn %.4f", current), at: frameTime)
    }

    /// Takes in what the Dock reader last learned: a new measurement of the bars, and when it read.
    private func take(_ reading: DockReader.Reading) {
        if reading.layoutsVersion != layoutsVersion {
            layoutsVersion = reading.layoutsVersion
            logMismatch(reading.mismatch)
            if !reading.layouts.isEmpty {
                record("layout v\(reading.layoutsVersion): " + reading.layouts.map { bar in
                    String(format: "%d thumbnails h %.0f, first at %.0f, labels ", bar.buttons.count, bar.frame.height,
                           bar.buttons.first?.frame.midX ?? -1)
                        + bar.captions.map { "\($0.spaceID)@\(Int($0.centre.x.rounded()))" }.joined(separator: " ")
                }.joined(separator: " | "), at: reading.answered)
                restingLayouts = reading.layouts.map { $0.atRest() }
                settleDrop(reading.layouts, answered: reading.answered)
                logOutcome("Spaces Bar found, \(reading.layouts.reduce(0) { $0 + $1.captions.count }) labels shown")
                for layout in reading.layouts where layout.frame.height > Self.expandedBarHeight {
                    let centred = layout.atRest().centred()
                    expandedLayouts[layout.displayID] = centred
                    expandedLayoutsByCount["\(layout.displayID)|\(layout.buttons.count)"] = centred
                }
                if let running = grow, let reported = reading.layouts.first(where: {
                    $0.screen == running.screen && $0.frame.height > Self.expandedBarHeight
                }) {
                    // The Dock reports the thumbnails it is growing: take their places from it.
                    var to = reported.atRest()
                    to.captions = running.to.captions.count == to.captions.count ? to.captions : running.to.captions
                    grow?.to = to
                } else {
                    // The reader noticed the change as it began this reading.
                    let changedAt = latestReadingTime > 0 ? (latestReadingTime + reading.time) / 2 : reading.time
                    if !noticeDesktopsChange(from: shownLayouts, to: reading.layouts, at: changedAt) {
                        noticeShift(from: shownLayouts, to: reading.layouts, at: changedAt)
                    }
                }
                shownLayouts = reading.layouts
            }
        }
        guard reading.answered != latestReadingTime else { return }
        previousReadingTime = latestReadingTime
        latestReadingTime = reading.answered
        record((reading.barFrame.map { String(format: "dock bar y %.1f h %.0f", $0.minY, $0.height) } ?? "dock no bar")
               + String(format: ", asked %.4f, requested %.4f", reading.time, reading.requested), at: reading.answered)
    }

    /// The Dock reports the hover-expanded thumbnails at their new places as they start sliding
    /// sideways: slide the labels there on its timing, from where they are now.
    private func noticeShift(from old: [BarLayout], to new: [BarLayout], at time: TimeInterval) {
        guard let before = old.first, let after = new.first,
              let dx = Self.uniformShift(from: before, to: after), abs(dx) > 0.5
        else {
            if let before = old.first, let after = new.first, before.frame != after.frame { shift = nil }
            return
        }
        // A slide still running leaves the labels short of the places it was taking them to.
        let left = shift.map { $0.slide.offset(at: time) } ?? 0
        shift = (after.screen, TimedShift(timing: DockMotion.shift, reference: time, from: left - dx))
        record(String(format: "shift %.1f", dx), at: time)
    }

    /// How far every caption of a bar moved sideways between two measurements of the same bar, or nil
    /// if they didn't all move together.
    static func uniformShift(from old: [CGPoint], to new: [CGPoint]) -> CGFloat? {
        guard !old.isEmpty, old.count == new.count else { return nil }
        let dx = new[0].x - old[0].x
        let together = zip(old, new).allSatisfy { abs(($1.x - $0.x) - dx) <= 1 && abs($1.y - $0.y) <= 1 }
        return together ? dx : nil
    }

    private static func uniformShift(from old: BarLayout, to new: BarLayout) -> CGFloat? {
        guard old.frame == new.frame else { return nil }
        return uniformShift(from: old.captions.map(\.centre), to: new.captions.map(\.centre))
    }

    /// About when the Dock made the change its latest reading shows: between that answer and the one before.
    private var readingChangedAt: TimeInterval {
        previousReadingTime > 0 ? (previousReadingTime + latestReadingTime) / 2 : latestReadingTime
    }

    /// Whether the Dock is moving the bar with the current swipe. It doesn't with some: pulling down
    /// after pushing the open Mission Control up arrives as a fresh closing swipe, which it ignores.
    /// Closing shows within a point of travel. Opening shows once the Dock reports the bar: for the
    /// first 140-300ms of an opening swipe the Dock is busy setting Mission Control up, and the bar on
    /// screen doesn't follow the fingers, so neither do the labels.
    private func dockTookSwipe(dock: CGFloat?) -> Bool {
        swipe.gestureStart < 0.5 ? (dock ?? 0) > 0.001 : dock != nil
    }

    private func placement(
        reading: DockReader.Reading, dock: CGFloat?, now: TimeInterval, frameTime: TimeInterval
    ) -> Placement {
        let confirmed = swipe.gesture == confirmedGesture
        switch swipe.state {
        case .swiping(let swipeRetraction):
            // The swipe moves the bar, not a replayed open.
            slide = nil
            if confirmed {
                // Fingers down: the trackpad's progress is finer and more frequent than the Dock's.
                return .at(swipeRetraction)
            }
            return swipe.gestureStart < 0.5 ? .at(dock ?? retraction) : .hidden
        case .released where !confirmed:
            // The Dock never acted on this swipe: carry on as before it.
            swipe.settle()
            return restingPlacement(reading: reading, dock: dock, now: now, frameTime: frameTime)
        case let .released(time, released, direction, _):
            return releasedPlacement(
                SwipeRelease(time: time, retraction: released, direction: direction),
                reading: reading, dock: dock, now: now, frameTime: frameTime)
        case .idle:
            return restingPlacement(reading: reading, dock: dock, now: now, frameTime: frameTime)
        }
    }

    private struct SwipeRelease {
        let time: TimeInterval
        let retraction: CGFloat
        let direction: CGFloat
    }

    /// Once the fingers lift, the Dock finishes the swipe and reports the bar as it goes, within about
    /// a frame of the bar on screen: follow its reports.
    private func releasedPlacement(
        _ release: SwipeRelease, reading: DockReader.Reading, dock: CGFloat?, now: TimeInterval,
        frameTime: TimeInterval
    ) -> Placement {
        if now - release.time < Self.handOffWindow {
            return .at(dock.map {
                Self.handOff(dockRetraction: $0, released: release.retraction, direction: release.direction)
            } ?? release.retraction)
        }
        if let dock {
            swipe.settle()
            return .at(dock)
        }
        // Still waiting for the Dock's report: hidden, as the bar may already be elsewhere.
        if now - release.time < Self.releaseGrace { return .hidden }
        swipe.settle()
        return restingPlacement(reading: reading, dock: dock, now: now, frameTime: frameTime)
    }

    /// No fingers on the trackpad: replay a slide the Dock reports only the end of, or follow the Dock.
    private func restingPlacement(
        reading: DockReader.Reading, dock: CGFloat?, now: TimeInterval, frameTime: TimeInterval
    ) -> Placement {
        if let timed = slide,
           let placement = timedPlacement(timed, reading: reading, dock: dock, frameTime: frameTime) {
            return placement
        }
        if let dock {
            // A close from the keyboard or a click: the Dock reports the bar fully up at once.
            if retraction <= Self.restSlack, dock >= 0.9 {
                return startClose(reference: readingChangedAt, frameTime: frameTime)
            }
            return .at(dock)
        }
        // Before the reader's first answer, or while Mission Control is still appearing, keep waiting.
        if reading.time == 0 || now - trackingStarted < Self.appearGrace { return .hidden }
        // The bar has gone. From rest, a close is starting: Ctrl+Up drops Mission Control from the
        // Dock's Accessibility as the bar starts up. From off the screen, one has ended.
        if sawBar, retraction <= Self.restSlack, !restingLayouts.isEmpty {
            return startClose(reference: readingChangedAt, frameTime: frameTime)
        }
        return .gone
    }

    /// Where a replayed slide puts the labels, or nil once it is over and the Dock has the bar.
    private func timedPlacement(
        _ timed: TimedSlide, reading: DockReader.Reading, dock: CGFloat?, frameTime: TimeInterval
    ) -> Placement? {
        let closing = timed.to > timed.from
        // The Dock answers an open only once the bar is in, so an answer with no bar means it wasn't
        // Mission Control, such as App Exposé, which the window server announces the same way.
        if !closing, reading.time > timed.reference, dock == nil, reading.layouts.isEmpty {
            slide = nil
            record("not Mission Control")
            return .gone
        }
        if !timed.isFinished(at: frameTime) {
            // A close turned back: the Dock reports the bar coming back in.
            if closing, timed.timing != DockMotion.choose, let dock, dock <= Self.restSlack,
               reading.time > timed.reference {
                let reverse = TimedSlide(timing: DockMotion.reverse, reference: readingChangedAt,
                                         from: timed.retraction(at: readingChangedAt), to: 0)
                slide = reverse
                record("reverse", at: readingChangedAt)
                return .slide(reverse)
            }
            return .slide(timed)
        }
        if closing {
            slide = nil
            return .gone
        }
        // Open. The Dock answers about when the bar lands: hold the labels in place until it does.
        if dock != nil {
            slide = nil
            return nil
        }
        if frameTime < timed.timing.end(from: timed.reference) + Self.openAnswerLimit { return .at(timed.to) }
        slide = nil
        return .gone
    }

    /// Starts replaying the close the Dock has just begun, timed from `reference`.
    private func startClose(reference: TimeInterval, frameTime: TimeInterval) -> Placement {
        let expanded = (restingLayouts.first?.frame.height ?? 0) > Self.expandedBarHeight
        let close = TimedSlide(timing: expanded ? DockMotion.closeExpanded : DockMotion.close,
                               reference: reference, from: retraction, to: 1)
        slide = close
        record(expanded ? "close expanded" : "close", at: reference)
        return .slide(close)
    }

    private static func interpolate(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        let minX = from.minX + (to.minX - from.minX) * progress
        let minY = from.minY + (to.minY - from.minY) * progress
        let maxX = from.maxX + (to.maxX - from.maxX) * progress
        let maxY = from.maxY + (to.maxY - from.maxY) * progress
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// How far a Dock Spaces Bar has slid up off its screen, as a fraction of its height:
    /// 0 at rest, 1 entirely above the screen's top edge.
    ///
    /// While a trackpad swipe opens or closes Mission Control, the Dock reports the bar's position
    /// as it slides, in step with the fingers and through the Dock's own finishing animation.
    /// Keyboard opens and closes report only the end position. Measured on macOS 26.7 on two
    /// displays. Frames are in AX coordinates: origin at the top-left of the primary display, y down.
    static func retraction(bar: CGRect, screen: CGRect) -> CGFloat {
        guard bar.height > 0 else { return 0 }
        return min(max((screen.minY - bar.minY) / bar.height, 0), 1)
    }

    /// `retraction(bar:screen:)` on the screen that holds the middle of the bar's bottom edge.
    static func retraction(bar: CGRect, screens: [CGRect]) -> CGFloat? {
        let foot = CGPoint(x: bar.midX, y: bar.maxY)
        guard bar.height > 0, let screen = screens.first(where: { $0.contains(foot) }) else { return nil }
        return retraction(bar: bar, screen: screen)
    }

    /// After the fingers lift, the Dock's reports can trail the bar on screen; holding the labels where
    /// they are (`released`) until a report passes them stops them stepping back against the swipe.
    static func handOff(dockRetraction: CGFloat, released: CGFloat, direction: CGFloat) -> CGFloat {
        if direction > 0 { return max(dockRetraction, released) }
        if direction < 0 { return min(dockRetraction, released) }
        return dockRetraction
    }

    private func appElement(_ bundleID: String) -> AXUIElement? {
        if let cached = apps[bundleID] { return cached.element }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).first else {
            apps[bundleID] = nil
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
        apps[bundleID] = (app.processIdentifier, element)
        return element
    }
}
