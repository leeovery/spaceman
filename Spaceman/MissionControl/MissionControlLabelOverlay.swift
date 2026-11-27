//
//  MissionControlLabelOverlay.swift
//  Spaceman
//
//  Draws the Mission Control name labels: one click-through window along the top of each screen,
//  holding every label on that screen as a Core Animation layer. Each frame sets the layers' places
//  itself and sends them to the screen at once. Moving AppKit views instead left the screen showing
//  labels where the bar had been for up to seconds, while Spaceman had already moved them.
//
//  The labels sit at their resting places in one layer that moves them all up and down. A slide
//  replayed on the Dock's timing runs as an animation of that layer, which the window server works
//  out for the frame it draws. Moved by Spaceman each frame instead, the labels reached the screen
//  one to two frames after the bar, 4-9pt behind it at full speed.
//
//  In Mission Control the window server redraws the window only when Spaceman changes something in
//  it, not for the animation alone, which then never shows. So while a slide runs, a 2x2-point layer
//  in the corner flips between two all-but-transparent shades every frame. The window server then
//  draws the slide as at the frame's time or one frame before, depending on when the change reaches
//  it (measured in Mission Control on macOS 26.7).
//

import AppKit

/// A name label to draw, centred on `centre` on the screen whose frame is `screen`. Both are in
/// AX coordinates: origin at the top-left of the primary display, y down. With a `look`, or on a
/// magnifying bar a `strip` face, the label is drawn to match the native caption it covers, with its
/// top-left at `lookOrigin`; otherwise as a box: on a `plate`, or in its space's colour, or black for a
/// space without one.
struct MissionControlLabel {
    let name: String
    let covers: String
    let maxWidth: CGFloat
    let colorHex: String?
    let centre: CGPoint
    let screen: CGRect
    var look: NativeCaptionLook.Variant?
    var strip: StripFace?
    var plate: LabelPlate?
    var lookOrigin: CGPoint?
    /// How far the plate reaches past the `look` either side, in the colour given.
    var lookPadding: (width: CGFloat, fill: CGColor)?
    /// The height of the bar the label is on: how far a retraction of 1 moves it up.
    var barHeight: CGFloat = 0
    /// The bar's thumbnails sliding sideways to where the label is placed.
    var shift: TimedShift?
    /// The label moving to where it is placed on its own, as the bar of names grows into thumbnails.
    var grow: TimedMove?
    /// Which label this is, its space's, for the debug recording.
    var key = ""
}

/// A plain plate a label is drawn on, with its name in the native caption's text: the bar's colour, the text's, the
/// plate's size, and how far below its top the name's baseline sits.
struct LabelPlate: Equatable {
    let fill: CGColor
    let text: CGColor
    let size: CGSize
    let baseline: CGFloat
}

/// Where a shown label is on screen at a moment, in AX coordinates, for the debug recording.
struct DrawnLabel: Equatable {
    let key: String
    let frame: CGRect
}

final class MissionControlLabelOverlay {

    /// Height of one label, which the caption positions are worked out from.
    static var labelHeight: CGFloat { LabelLayer.height }
    /// How far down each screen the label windows reach: far enough for hover-expanded thumbnails.
    static let stripHeight: CGFloat = 400

    private var windows: [OverlayWindow] = []
    /// The label windows' level: see `level(windows:over:dockPID:)`.
    var level = MissionControlLabelOverlay.defaultLevel {
        didSet { for window in windows { window.level = NSWindow.Level(rawValue: level) } }
    }
    /// Whether the label windows belong to every desktop: see `showOnEveryDesktop`.
    private var onEveryDesktop = true
    private var lastRaise: TimeInterval = 0
    /// Mission Control can reorder its windows; keep the labels on top, at most this often.
    private static let raiseInterval: TimeInterval = 0.25

    /// Draws `labels`, moved up off their screens by `retraction` of their bars' heights, or by
    /// `slide` as it runs.
    /// With `redrawing`, every window is redrawn whole this frame, whatever changed: while a thumbnail is
    /// dragged, macOS has been seen to keep showing a label that was hidden.
    func render(
        _ labels: [MissionControlLabel], retraction: CGFloat = 0, slide: TimedSlide? = nil, redrawing: Bool = false
    ) {
        let style = LabelLayer.Style.current
        var screens: [CGRect] = []
        for label in labels where !screens.contains(label.screen) {
            screens.append(label.screen)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in screens {
            window(for: screen).show(
                labels.filter { $0.screen == screen }, style: style, retraction: retraction, slide: slide,
                redrawing: redrawing)
        }
        for window in windows where window.isVisible && !screens.contains(window.axScreen) {
            window.show([], style: style, retraction: retraction, slide: nil, redrawing: redrawing)
        }
        CATransaction.commit()
        // Send the labels' new places to the screen now, not whenever the run loop next idles.
        CATransaction.flush()

        let now = ProcessInfo.processInfo.systemUptime
        let raise = now - lastRaise >= Self.raiseInterval
        if raise { lastRaise = now }
        for window in windows where screens.contains(window.axScreen) {
            if raise || !window.isVisible { window.orderFrontRegardless() }
        }
    }

    /// Puts an empty window on each of `screens` ahead of the labels: a window ordered in reaches the screen
    /// about three frames after (filmed on macOS 26.7), one made afresh about six, while the labels it then shows
    /// would be on time. Each stays until `hide`, empty while its screen has no labels.
    func prepare(screens: [CGRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in screens { window(for: screen).show([], style: .current, retraction: 0, slide: nil) }
        CATransaction.commit()
        CATransaction.flush()
        for screen in screens { window(for: screen).orderFrontRegardless() }
    }

    /// Whether any label window is on screen.
    var isShowing: Bool { windows.contains { $0.isVisible } }

    func hide() {
        for window in windows {
            window.stopSlide()
            window.stopShift()
            if window.isVisible { window.orderOut(nil) }
        }
    }

    func close() {
        for window in windows { window.close() }
        windows = []
    }

    /// Whether the labels belong to every desktop, as they must to show over Mission Control whichever
    /// desktop it opened on, or only to this one: macOS draws the windows of every desktop into the
    /// zoom to a desktop chosen in Mission Control.
    func showOnEveryDesktop(_ every: Bool) {
        onEveryDesktop = every
        for window in windows { window.joinsEveryDesktop(every) }
    }

    /// For the debug recording: the labels shown on `screen`'s window.
    func layerState(for screen: CGRect) -> String {
        windows.first { $0.axScreen == screen }.map { "\($0.isVisible ? "shown" : "hidden") window: \($0.layerState)" }
            ?? "no window"
    }

    /// For the debug recording: where each shown label is placed for `time` (system uptime), with the
    /// slides and moves handed to the window server worked out for that moment.
    func drawnLabels(at time: TimeInterval) -> [DrawnLabel] {
        windows.filter(\.isVisible).flatMap { $0.drawnLabels(at: time) }
    }

    /// For the debug trace: each window's screen, and whether it is hidden, or shown and visible to
    /// macOS or covered.
    var debugState: String {
        windows.map { window in
            let state = !window.isVisible ? "hidden"
                : window.occlusionState.contains(.visible) ? "shown" : "occluded"
            return "\(Int(window.axScreen.minX)):\(state)"
        }.joined(separator: " ")
    }

    private func window(for screen: CGRect) -> OverlayWindow {
        if let existing = windows.first(where: { $0.axScreen == screen }) { return existing }
        let window = OverlayWindow(screen: screen, level: level)
        window.joinsEveryDesktop(onEveryDesktop)
        windows.append(window)
        return window
    }
}

// MARK: - OverlayWindow

// MARK: - Level

/// A window on screen as the window server lists it, which needs no Screen Recording permission: its layer, its
/// owner and its bounds in AX coordinates; and its name, where the listing gives one.
struct ListedWindow: Equatable {
    let layer: Int
    let owner: String
    let pid: pid_t
    let bounds: CGRect
    let name: String?

    /// Every window on screen, front to back; nil when the window server lists none.
    static func onScreen() -> [ListedWindow]? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return info.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return ListedWindow(layer: layer, owner: entry[kCGWindowOwnerName as String] as? String ?? "?", pid: pid,
                                bounds: bounds, name: entry[kCGWindowName as String] as? String)
        }
    }
}

extension MissionControlLabelOverlay {

    /// The label windows' level without a better one: over everything.
    static let defaultLevel = Int(CGWindowLevelForKey(.screenSaverWindow)) + 1
    /// How far down a screen's top windows lie entirely to count as the menu bar's: the bar and its status items.
    static let menuBarDepth: CGFloat = 50

    /// The label windows' level, from the `windows` on screen and the bars' `areas`: just above the Dock's highest
    /// window there, which holds the Spaces Bar and what Mission Control draws, and below the menu bar's windows,
    /// or the main menu's level where none shows. As Mission Control closes, macOS brings the menu bar back over its
    /// captions; there, it covers the labels too. `defaultLevel` with no list, no Dock window there or no room.
    static func level(
        windows: [ListedWindow]?, over areas: [CGRect], dockPID: pid_t
    ) -> (level: Int, reason: String) {
        guard let windows else { return (defaultLevel, "kept: no window list") }
        let over = windows.filter { window in areas.contains { $0.intersects(window.bounds) } }
        guard let dock = over.filter({ $0.pid == dockPID }).map(\.layer).max() else {
            return (defaultLevel, "kept: no Dock window over the bar")
        }
        let menuBar = over.filter { window in
            window.pid != dockPID && window.layer > 0 && areas.contains {
                $0.minY <= window.bounds.minY && window.bounds.maxY <= $0.minY + menuBarDepth
                    && $0.intersects(window.bounds)
            }
        }
        let ceiling = (menuBar.map(\.layer) + [Int(CGWindowLevelForKey(.mainMenuWindow))]).min() ?? dock
        guard dock + 1 < ceiling else {
            return (defaultLevel, "kept: no room between the Dock's layer \(dock) and the menu bar's \(ceiling)")
        }
        return (dock + 1, "above the Dock's layer \(dock), below the menu bar's \(ceiling)")
    }

    /// `windows` over the bars' `areas`, for the debug recording: each one off the normal layer as "layer owner
    /// "name" x,y,w,h", front to back, and how many more are on it.
    static func describe(_ windows: [ListedWindow], over areas: [CGRect]) -> String {
        let over = windows.filter { window in areas.contains { $0.intersects(window.bounds) } }
        let raised = over.filter { $0.layer != 0 }.map { window in
            let bounds = window.bounds
            return "\(window.layer) \(window.owner)" + (window.name.map { " \"\($0)\"" } ?? "")
                + String(format: " %.0f,%.0f,%.0f,%.0f", bounds.minX, bounds.minY, bounds.width, bounds.height)
        }
        return (raised + ["+\(over.count - raised.count) at layer 0"]).joined(separator: "; ")
    }
}

/// A transparent strip along the top of one screen, tall enough for hover-expanded thumbnails.
private final class OverlayWindow: NSWindow {

    /// The screen's frame in AX coordinates.
    let axScreen: CGRect
    private let root = CALayer()
    /// Holds the labels at their resting places and moves them up together.
    private let slider = CALayer()
    private var layers: [LabelLayer] = []
    /// Changed whenever a label is hidden or shown, so the window server redraws the whole window: it
    /// has been seen to keep showing a label hidden as a thumbnail was picked up.
    private var redrawn = false
    /// The slides the slider is animating, if any.
    private var runningSlide: TimedSlide?
    /// The bar height `runningSlide` moves the labels by.
    private var runningSlideHeight: CGFloat = 0
    private var runningShift: TimedShift?
    /// Changed a little each frame while a slide runs, so the window server redraws the window.
    private let nudgeLayer = CALayer()
    private var nudged = false
    private static let slideKey = "slide"
    private static let shiftKey = "shift"
    /// Keyframes per slide: one every 4-6ms, finer than a frame.
    private static let slideSteps = 60

    init(screen: CGRect, level: Int) {
        self.axScreen = screen
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let height = min(MissionControlLabelOverlay.stripHeight, screen.height)
        let frame = CGRect(
            x: screen.minX,
            y: primaryTop - screen.minY - height,
            width: screen.width,
            height: height)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: level)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Without this, macOS plays its window-opening animation each time the strip is shown, so
        // the labels arrive scaled down towards the strip's centre and spread out over a few frames.
        animationBehavior = .none

        // Layer-hosting: the labels are layers Spaceman places itself, not views AppKit lays out.
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.layer = root
        content.wantsLayer = true
        contentView = content
        slider.anchorPoint = .zero
        slider.frame = CGRect(origin: .zero, size: frame.size)
        slider.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        root.actions = ["backgroundColor": NSNull()]
        root.backgroundColor = NSColor(white: 1, alpha: 1 / 255).cgColor
        root.addSublayer(slider)
        nudgeLayer.frame = CGRect(x: 0, y: frame.height - 2, width: 2, height: 2)
        nudgeLayer.actions = ["backgroundColor": NSNull()]
        root.addSublayer(nudgeLayer)
    }


    func joinsEveryDesktop(_ every: Bool) {
        if every {
            collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            collectionBehavior.remove(.canJoinAllSpaces)
        }
    }

    func show(
        _ labels: [MissionControlLabel], style: LabelLayer.Style, retraction: CGFloat, slide: TimedSlide?,
        redrawing: Bool = false
    ) {
        while layers.count < labels.count {
            let layer = LabelLayer()
            slider.addSublayer(layer)
            layers.append(layer)
        }
        let scale = backingScaleFactor
        let height = frame.height
        let wereShown = layers.filter { !$0.isHidden }.map(\.key)
        for (index, layer) in layers.enumerated() {
            guard index < labels.count else {
                if !layer.isHidden { layer.isHidden = true }
                continue
            }
            let label = labels[index]
            layer.key = label.key
            layer.configure(label, style: style, scale: scale)
            let size = layer.bounds.size
            // The label's top-left in AX coordinates: a matched look is placed for it; a box is centred.
            let topLeft = label.lookOrigin.map { CGPoint(x: $0.x - (label.lookPadding?.width ?? 0), y: $0.y) }
                ?? CGPoint(x: label.centre.x - size.width / 2, y: label.centre.y - size.height / 2)
            // Window-local coordinates, with y up from the strip's bottom, on whole device pixels.
            let origin = CGPoint(
                x: ((topLeft.x - axScreen.minX) * scale).rounded() / scale,
                y: ((height - (topLeft.y - axScreen.minY) - size.height) * scale).rounded() / scale)
            if layer.position != origin { layer.position = origin }
            if layer.isHidden { layer.isHidden = false }
            layer.move(label.grow, steps: Self.slideSteps)
        }
        if redrawing || layers.filter({ !$0.isHidden }).map(\.key) != wereShown {
            redrawn.toggle()
            root.backgroundColor = NSColor(white: 1, alpha: redrawn ? 2 / 255 : 1 / 255).cgColor
        }
        lift(barHeight: labels.first?.barHeight ?? 0, retraction: retraction, slide: slide)
        glide(labels.first?.shift)
        if runningSlide != nil || runningShift != nil || labels.contains(where: { $0.grow != nil }) { nudge() }
    }

    /// For the debug recording: the labels shown, left to right, as each layer's key at its x as set
    /// and as on screen, and how many are hidden.
    var layerState: String {
        let shown = layers.filter { !$0.isHidden }.sorted { $0.position.x < $1.position.x }
        let parts = shown.map { layer in
            let onScreen = layer.presentation()?.position.x ?? layer.position.x
            return "\(layer.key)@\(Int(layer.position.x.rounded()))/\(Int(onScreen.rounded()))"
        }
        return parts.joined(separator: " ") + ", \(layers.count - shown.count) hidden"
    }

    /// Where each shown label is placed for `time`: its place, moved by the animations running then.
    /// These follow the curves the animations' keyframes are taken from, which are close enough together
    /// for the two to differ by well under a point. The window server may show a slide as it was a frame
    /// earlier: see the header.
    func drawnLabels(at time: TimeInterval) -> [DrawnLabel] {
        let lift = runningSlide.map { $0.retraction(at: time) * runningSlideHeight } ?? slider.position.y
        let glide = runningShift?.offset(at: time) ?? slider.position.x
        return layers.filter { !$0.isHidden }.map { layer in
            let size = layer.bounds.size
            let moved = layer.offset(at: time)
            // Window-local y runs up from the strip's bottom; AX y runs down from the top.
            let origin = CGPoint(
                x: axScreen.minX + glide + layer.position.x + moved.dx,
                y: axScreen.minY + frame.height - (lift + layer.position.y + size.height) + moved.dy)
            return DrawnLabel(key: layer.key, frame: CGRect(origin: origin, size: size))
        }
    }

    private func nudge() {
        nudged.toggle()
        nudgeLayer.backgroundColor = NSColor(white: 1, alpha: nudged ? 2 / 255 : 1 / 255).cgColor
    }

    func stopSlide() {
        guard runningSlide != nil else { return }
        slider.removeAnimation(forKey: Self.slideKey)
        runningSlide = nil
    }

    func stopShift() {
        guard runningShift != nil else { return }
        slider.removeAnimation(forKey: Self.shiftKey)
        runningShift = nil
    }

    /// Slides the labels sideways with `shift`, or holds them where they are placed.
    private func glide(_ shift: TimedShift?) {
        guard let shift else {
            stopShift()
            if slider.position.x != 0 { slider.position.x = 0 }
            return
        }
        guard shift != runningShift else { return }
        slider.removeAnimation(forKey: Self.shiftKey)
        runningShift = shift
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = shift.keyframes(steps: Self.slideSteps)
        animation.keyTimes = (0...Self.slideSteps).map { NSNumber(value: Double($0) / Double(Self.slideSteps)) }
        animation.calculationMode = .linear
        let start = CACurrentMediaTime() + shift.start - ProcessInfo.processInfo.systemUptime
        animation.beginTime = slider.convertTime(start, from: nil)
        animation.duration = shift.timing.duration
        animation.fillMode = .both
        slider.add(animation, forKey: Self.shiftKey)
        slider.position.x = 0
    }

    /// Moves the labels up `retraction` of the bar's height, or animates them with `slide`.
    private func lift(barHeight: CGFloat, retraction: CGFloat, slide: TimedSlide?) {
        let scale = backingScaleFactor
        // Window-local y is up: a bar going off the top of the screen moves up.
        let points = { (retraction: CGFloat) in (retraction * barHeight * scale).rounded() / scale }
        guard let slide, barHeight > 0 else {
            stopSlide()
            let y = points(retraction)
            if slider.position.y != y { slider.position.y = y }
            return
        }
        guard slide != runningSlide else { return }
        slider.removeAnimation(forKey: Self.slideKey)
        runningSlide = slide
        runningSlideHeight = barHeight
        let animation = CAKeyframeAnimation(keyPath: "position.y")
        animation.values = slide.keyframes(steps: Self.slideSteps).map { $0 * barHeight }
        animation.keyTimes = (0...Self.slideSteps).map { NSNumber(value: Double($0) / Double(Self.slideSteps)) }
        animation.calculationMode = .linear
        // From system uptime to Core Animation's clock, then to the layer's.
        let start = CACurrentMediaTime() + slide.start - ProcessInfo.processInfo.systemUptime
        animation.beginTime = slider.convertTime(start, from: nil)
        animation.duration = slide.timing.duration
        // Held at its first value until it starts, and its last once it ends.
        animation.fillMode = .both
        slider.add(animation, forKey: Self.slideKey)
        slider.position.y = points(slide.to)
    }
}

// MARK: - LabelLayer

/// One name label, covering a "Desktop N" caption: the matched look's image, a caption strip cropped
/// under the name, or a box with the name in its space's colour.
private final class LabelLayer: CALayer {

    struct Style: Equatable {
        let decoration: Int

        static var current: Style {
            Style(decoration: UserDefaults.standard.integer(forKey: "decorationActive"))
        }
    }

    private struct Content: Equatable {
        let name: String
        let covers: String
        let maxWidth: CGFloat
        let colorHex: String?
        let style: Style
        let plate: LabelPlate?
    }

    /// The label's key, for the debug recording.
    var key = ""
    /// The move this label is animating on its own, if any.
    private var runningMove: TimedMove?
    private static let moveKey = "move"

    private let text = CATextLayer()
    private var content: Content?
    /// The matched look's image, while showing one, and how far past it its plate reaches.
    private var lookImage: CGImage?
    private var lookPadding: CGFloat = 0
    /// While showing a strip face, whose strip is the layer's contents: the face, and its name.
    private var stripFace: StripFace?
    private let stripName = CALayer()

    private static let padding = NSSize(width: 6, height: 2)
    /// Room either side of the name inside the box, as the text field this replaced left.
    private static let textInset: CGFloat = 2
    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    private static let plateFont = NSFont.systemFont(ofSize: MissionControlCaptionLook.nativeFontSize)

    /// Labels jump to each frame's place: no implicit animation of anything they change.
    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(),
        "hidden": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(),
        "contentsScale": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "contentsRect": NSNull(),
    ]

    static var height: CGFloat { height(of: font) }

    private static func height(of font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + padding.height * 2
    }

    override init() {
        super.init()
        anchorPoint = .zero
        actions = Self.noActions
        backgroundColor = NSColor.black.cgColor
        text.actions = Self.noActions
        text.font = Self.font
        text.fontSize = Self.font.pointSize
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.truncationMode = .end
        addSublayer(text)
        stripName.actions = Self.noActions
        stripName.isHidden = true
        addSublayer(stripName)
        stripName.contentsGravity = .resize
    }

    /// Core Animation's copy of a layer, as for its presentation layer.
    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sets the image or text, colours and size; skipped when nothing changed, as it runs every frame.
    func configure(_ label: MissionControlLabel, style: Style, scale: CGFloat) {
        if contentsScale != scale {
            contentsScale = scale
            text.contentsScale = scale
            stripName.contentsScale = scale
        }
        if let face = label.strip {
            show(face)
            return
        }
        if stripFace != nil { leaveStrip() }
        if let look = label.look {
            let padding = label.lookPadding?.width ?? 0
            guard look.image !== lookImage || padding != lookPadding else { return }
            lookImage = look.image
            lookPadding = padding
            content = nil
            text.isHidden = true
            backgroundColor = padding > 0 ? label.lookPadding?.fill : nil
            cornerRadius = 0
            contents = look.image
            contentsGravity = padding > 0 ? .center : .resize
            bounds = CGRect(origin: .zero, size: CGSize(width: look.frame.width + 2 * padding,
                                                        height: look.frame.height))
            return
        }
        if lookImage != nil {
            lookImage = nil
            contents = nil
            text.isHidden = false
        }
        let wanted = Content(
            name: label.name, covers: label.covers, maxWidth: label.maxWidth,
            colorHex: label.colorHex, style: style, plate: label.plate)
        guard wanted != content else { return }
        content = wanted

        text.string = label.name
        if let plate = label.plate {
            show(plate)
            return
        }
        let font = Self.font
        let height = Self.height(of: font)
        text.font = font
        text.fontSize = font.pointSize
        if let hex = label.colorHex, let color = NSColor.fromHex(hex) {
            backgroundColor = color.cgColor
            text.foregroundColor = color.contrastingTextColor.cgColor
        } else {
            backgroundColor = NSColor.black.cgColor
            text.foregroundColor = NSColor.white.cgColor
        }
        let iconStyle = IconStyle(rawValue: style.decoration) ?? .filledRounded
        cornerRadius = iconStyle.cornerRadius(for: NSRect(x: 0, y: 0, width: 0, height: height))

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let nameWidth = (label.name as NSString).size(withAttributes: attrs).width
        let coversWidth = (label.covers as NSString).size(withAttributes: attrs).width
        let width = min(
            ceil(max(nameWidth, coversWidth) + Self.textInset * 2) + Self.padding.width * 2, label.maxWidth)
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // A text layer draws its line from the top: this centres it in the box as the text field did.
        text.frame = CGRect(x: 0, y: Self.padding.height, width: width, height: height - Self.padding.height * 2)
    }

    /// Shows the name, already set, on `plate`, its baseline where the plate has it.
    private func show(_ plate: LabelPlate) {
        let font = Self.plateFont
        text.font = font
        text.fontSize = font.pointSize
        text.foregroundColor = plate.text
        backgroundColor = plate.fill
        cornerRadius = 0
        bounds = CGRect(origin: .zero, size: plate.size)
        let line = ceil(font.ascender - font.descender + font.leading)
        text.frame = CGRect(x: 0, y: plate.size.height - (plate.baseline - font.ascender) - line,
                            width: plate.size.width, height: line)
    }

    /// Shows `face`: its strip as the layer's contents, cropped to the part behind the label, under its name and pill.
    private func show(_ face: StripFace) {
        guard face != stripFace else { return }
        if stripFace == nil {
            lookImage = nil
            content = nil
            text.isHidden = true
            backgroundColor = nil
            cornerRadius = 0
            contentsGravity = .resize
            stripName.isHidden = false
        }
        if stripFace?.strip !== face.strip { contents = face.strip }
        stripFace = face
        contentsRect = face.contentsRect
        let layout = face.layout
        bounds = CGRect(origin: .zero, size: layout.size)
        stripName.contents = face.name
        stripName.frame = Self.layerFrame(layout.nameFrame, height: layout.size.height)
    }

    private func leaveStrip() {
        stripFace = nil
        contents = nil
        contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        stripName.isHidden = true
        text.isHidden = false
        content = nil
    }

    /// `frame`, in points from the top-left of a layer `height` tall, y down, in the layer's own coordinates, y up.
    private static func layerFrame(_ frame: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The offset its own move gives it at `time`, in AX directions (y down).
    func offset(at time: TimeInterval) -> CGVector {
        runningMove?.offset(at: time) ?? .zero
    }

    /// Animates the label from an offset to where it is placed, on top of where it is placed, so it
    /// still follows the slider's slides.
    func move(_ move: TimedMove?, steps: Int) {
        guard move != runningMove else { return }
        removeAnimation(forKey: Self.moveKey)
        runningMove = move
        guard let move else { return }
        let animation = CAKeyframeAnimation(keyPath: "position")
        // Window coordinates run up, Accessibility's down.
        animation.values = move.keyframes(steps: steps).map { NSValue(point: CGPoint(x: $0.dx, y: -$0.dy)) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.calculationMode = .linear
        animation.isAdditive = true
        let start = CACurrentMediaTime() + move.start - ProcessInfo.processInfo.systemUptime
        animation.beginTime = convertTime(start, from: nil)
        animation.duration = move.timing.duration
        animation.fillMode = .both
        add(animation, forKey: Self.moveKey)
    }
}
