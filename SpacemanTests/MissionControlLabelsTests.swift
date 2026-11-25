//
//  MissionControlLabelsTests.swift
//  SpacemanTests
//

import AppKit
import CoreText
import XCTest
@testable import Spaceman

/// Frames measured on macOS 26.7 with a 2560x1440 primary display and a 1728x1117 built-in display
/// to its right, its top 904pt below the primary's top. All frames are in AX coordinates.
final class MissionControlLabelsTests: XCTestCase {

    private let primary = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let builtIn = CGRect(x: 2560, y: 904, width: 1728, height: 1117)
    private var screens: [CGRect] { [primary, builtIn] }

    private func retraction(_ bar: CGRect) -> CGFloat? {
        MissionControlLabels.retraction(bar: bar, screens: screens)
    }

    // MARK: - retraction

    func testBarsAtRestAreNotRetracted() {
        XCTAssertEqual(retraction(CGRect(x: 0, y: 0, width: 2560, height: 40)), 0)
        XCTAssertEqual(retraction(CGRect(x: 2560, y: 904, width: 1728, height: 72)), 0)
        // Hover-expanded
        XCTAssertEqual(retraction(CGRect(x: 0, y: 0, width: 2560, height: 146)), 0)
        XCTAssertEqual(retraction(CGRect(x: 2560, y: 904, width: 1728, height: 164)), 0)
    }

    func testBarsHalfwayThroughASwipeAreHalfRetracted() {
        XCTAssertEqual(retraction(CGRect(x: 0, y: -20, width: 2560, height: 40)), 0.5)
        XCTAssertEqual(retraction(CGRect(x: 2560, y: 868, width: 1728, height: 72)), 0.5)
    }

    func testBarsEntirelyAboveTheirScreensAreFullyRetracted() {
        XCTAssertEqual(retraction(CGRect(x: 0, y: -40, width: 2560, height: 40)), 1)
        XCTAssertEqual(retraction(CGRect(x: 2560, y: 832, width: 1728, height: 72)), 1)
        XCTAssertEqual(retraction(CGRect(x: 0, y: -146, width: 2560, height: 146)), 1)
        XCTAssertEqual(retraction(CGRect(x: 2560, y: 740, width: 1728, height: 164)), 1)
    }

    /// A retracted bar on the lower display must not be read as a bar at rest on a display above.
    func testRetractedBarBelowAnotherDisplayIsFullyRetracted() {
        let above = CGRect(x: 0, y: -1117, width: 1728, height: 1117)
        let bar = CGRect(x: 0, y: -40, width: 2560, height: 40)
        XCTAssertEqual(MissionControlLabels.retraction(bar: bar, screens: [primary, above]), 1)
    }

    func testBarOnNoKnownScreenHasNoRetraction() {
        XCTAssertNil(retraction(CGRect(x: 9000, y: 9000, width: 100, height: 40)))
    }

    func testEmptyBarHasNoRetraction() {
        XCTAssertNil(retraction(CGRect(x: 0, y: 0, width: 2560, height: 0)))
    }

    func testRetractionOnAKnownScreenIsClamped() {
        let bar = CGRect(x: 0, y: 10, width: 2560, height: 40)
        XCTAssertEqual(MissionControlLabels.retraction(bar: bar, screen: primary), 0)
        let gone = CGRect(x: 0, y: -60, width: 2560, height: 40)
        XCTAssertEqual(MissionControlLabels.retraction(bar: gone, screen: primary), 1)
    }

    // MARK: - Swipe progress

    func testSwipeUpFromClosedSlidesTheBarOn() {
        // Measured: progress -0.489 with the 40pt bar at y = -20.
        XCTAssertEqual(MissionControlSwipeTracker.retraction(start: 1, progress: -0.5), 0.5)
        XCTAssertEqual(MissionControlSwipeTracker.retraction(start: 1, progress: -1.08), 0)
    }

    func testSwipeDownFromOpenSlidesTheBarOff() {
        XCTAssertEqual(MissionControlSwipeTracker.retraction(start: 0, progress: 0.25), 0.25)
        XCTAssertEqual(MissionControlSwipeTracker.retraction(start: 0, progress: 1.08), 1)
    }

    func testSwipesThatMoveNoBarAreClamped() {
        // Swipe down while closed (App Exposé), or up while open.
        XCTAssertEqual(MissionControlSwipeTracker.retraction(start: 1, progress: 0.4), 1)
        XCTAssertEqual(MissionControlSwipeTracker.retraction(start: 0, progress: -0.4), 0)
    }

    func testSwipesFirstMovingTheWayNoBarCanGoMoveNoBar() {
        // Open, swiping up only pushes the windows back; closed, swiping down is App Exposé.
        XCTAssertFalse(MissionControlSwipeTracker.drivesBar(start: 0, progress: -0.05))
        XCTAssertFalse(MissionControlSwipeTracker.drivesBar(start: 1, progress: 0.05))
        XCTAssertTrue(MissionControlSwipeTracker.drivesBar(start: 0, progress: 0.05))
        XCTAssertTrue(MissionControlSwipeTracker.drivesBar(start: 1, progress: -0.05))
    }

    // MARK: - Hand-off from trackpad to Dock

    func testHandOffHoldsTheReleasedPositionAgainstTheSwipe() {
        // Released closing at 0.5; the Dock still reports 0.45.
        XCTAssertEqual(MissionControlLabels.handOff(dockRetraction: 0.45, released: 0.5, direction: 1), 0.5)
        XCTAssertEqual(MissionControlLabels.handOff(dockRetraction: 0.6, released: 0.5, direction: 1), 0.6)
        // Released opening at 0.3; the Dock still reports 0.35.
        XCTAssertEqual(MissionControlLabels.handOff(dockRetraction: 0.35, released: 0.3, direction: -1), 0.3)
        XCTAssertEqual(MissionControlLabels.handOff(dockRetraction: 0.1, released: 0.3, direction: -1), 0.1)
    }

    func testHandOffWithoutDirectionFollowsTheDock() {
        XCTAssertEqual(MissionControlLabels.handOff(dockRetraction: 0.2, released: 0.5, direction: 0), 0.2)
    }

    // MARK: - Native look

    private let barColor = (29, 20, 146)
    private let pillColor = (63, 56, 184)
    private let textColor = (245, 245, 252)

    private func cgColor(_ rgb: (Int, Int, Int)) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    /// A 2x capture of a 400x40pt bar drawn like macOS 26.7's: "Desktop 1" in the current-space pill
    /// centred at x = 100, "Desktop 2" on the bar at x = 300, both on a baseline 25pt down.
    private func syntheticBar() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 80, bitsPerComponent: 8, bytesPerRow: 800 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(cgColor(barColor))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 40))
        let baseline: CGFloat = 15  // 25pt down from the top, measured from the bottom
        for (text, centreX, inPill) in [("Desktop 1", CGFloat(100), true), ("Desktop 2", CGFloat(300), false)] {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(textColor),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if inPill {
                let pill = CGRect(x: centreX - ink.width / 2 - 11.5, y: baseline - 7, width: ink.width + 23, height: 24)
                context.setFillColor(cgColor(pillColor))
                context.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil))
                context.fillPath()
            }
            context.textPosition = CGPoint(x: centreX - ink.midX, y: baseline)
            CTLineDraw(line, context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// `image`'s pixels as sRGB, read from the top-left.
    private func pixels(_ image: CGImage) throws -> [[(Int, Int, Int)]] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (0..<image.height).map { y in
            (0..<image.width).map { x in
                let index = (y * image.width + x) * 4
                return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
            }
        }
    }

    private func assertColor(_ actual: (Int, Int, Int), _ expected: (Int, Int, Int), file: StaticString = #filePath,
                             line: UInt = #line) {
        let close = abs(actual.0 - expected.0) <= 3 && abs(actual.1 - expected.1) <= 3
            && abs(actual.2 - expected.2) <= 3
        XCTAssertTrue(close, "\(actual) is not \(expected)", file: file, line: line)
    }

    private func matchSyntheticBar() throws -> [String: NativeCaptionLook] {
        MissionControlCaptionLook.looks(in: try syntheticBar(), origin: .zero, scale: 2, captions: [
            CaptionToMatch(key: "current", centre: CGPoint(x: 100, y: 20),
                           barTop: 0, barBottom: 40, maxWidth: 96, covers: "Desktop 1",
                           name: "Personal"),
            CaptionToMatch(key: "other", centre: CGPoint(x: 300, y: 20),
                           barTop: 0, barBottom: 40, maxWidth: 96, covers: "Desktop 2",
                           name: "Fabric"),
            CaptionToMatch(key: "empty", centre: CGPoint(x: 200, y: 20),
                           barTop: 0, barBottom: 40, maxWidth: 96, covers: "Desktop 3",
                           name: "Nothing here"),
        ])
    }

    func testTheCurrentSpaceGetsAPillOverTheNativeOne() throws {
        let looks = try matchSyntheticBar()
        XCTAssertEqual(looks["current"]?.wasCurrent, true)
        let look = try XCTUnwrap(looks["current"]?.current)
        // The native pill, 24pt tall from 8pt down, in an image a pixel larger all round.
        XCTAssertEqual(look.frame.minY, -12.5, accuracy: 0.01)
        XCTAssertEqual(look.top, 7.5, accuracy: 0.01)
        XCTAssertEqual(look.frame.height, 25, accuracy: 0.01)
        // As wide as the native pill, though "Personal" is shorter than "Desktop 1".
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Desktop 1", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        let nativePill = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width + 23
        XCTAssertGreaterThanOrEqual(look.frame.width, nativePill)
        XCTAssertLessThanOrEqual(look.frame.width, nativePill + 2.5)
        let image = try pixels(look.image)
        // Inside the pill, left of the name: the pill's colour.
        assertColor(image[25][8], pillColor)
        // The corner outside the pill's rounding stays clear, so the bar shows through.
        XCTAssertEqual(image[0][0].0, 0)
    }

    func testOtherSpacesGetThePatchOfBarBehindTheirCaption() throws {
        let look = try XCTUnwrap(try matchSyntheticBar()["other"]?.plain)
        // As large as the bar's pill, 24pt from 8pt down, and a pixel more all round, so it hides the
        // pill too if Mission Control moves it here before Spaceman follows.
        XCTAssertEqual(look.frame.minY, -12.5, accuracy: 0.01)
        XCTAssertEqual(look.top, 7.5, accuracy: 0.01)
        XCTAssertEqual(look.frame.height, 25, accuracy: 0.01)
        let inPill = try XCTUnwrap(try matchSyntheticBar()["other"]?.current)
        XCTAssertGreaterThanOrEqual(look.frame.width, inPill.frame.width - 0.5)
        let image = try pixels(look.image)
        // Where the native "D" was, left of the shorter name: bar, with the native text erased.
        assertColor(image[30][1], barColor)
        assertColor(image[30][12], barColor)
        // The name is drawn in the native text's colour.
        let brightest = image.joined().max { $0.0 + $0.1 + $0.2 < $1.0 + $1.1 + $1.2 }
        assertColor(try XCTUnwrap(brightest), textColor)
    }

    /// On the built-in display the captions sit well below where the Dock's thumbnails put them, and
    /// hover-expanded thumbnails sit just above them: the caption is the lowest text in the bar.
    /// Switching spaces with Mission Control open moves the pill: every caption can be drawn either way.
    func testEveryCaptionCanBeDrawnPlainOrInThePill() throws {
        let looks = try matchSyntheticBar()
        // "Desktop 2" in the pill: the current space's pill colour, as tall as the native pill.
        let inPill = try XCTUnwrap(looks["other"]?.current)
        XCTAssertEqual(inPill.top, 7.5, accuracy: 0.01)
        XCTAssertEqual(inPill.frame.height, 25, accuracy: 0.01)
        assertColor(try pixels(inPill.image)[25][8], pillColor)
        // "Desktop 1" plain: bar, read from beside the pill it was captured in.
        let plain = try XCTUnwrap(looks["current"]?.plain)
        XCTAssertEqual(plain.top, 7.5, accuracy: 0.01)
        let image = try pixels(plain.image)
        assertColor(image[2][1], barColor)
        assertColor(image[45][1], barColor)
    }

    func testTheCaptionIsTheLowestTextAboveTheBarsBottom() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 120, bitsPerComponent: 8, bytesPerRow: 800 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(cgColor(barColor))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 60))
        // A bright thumbnail's bottom edge, 10 to 20pt down, above the caption.
        context.setFillColor(cgColor(textColor))
        context.fill(CGRect(x: 250, y: 40, width: 100, height: 10))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(textColor),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Desktop 2", attributes: attributes))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: 300 - ink.midX, y: 10)  // baseline 50pt down
        CTLineDraw(line, context)
        let image = try XCTUnwrap(context.makeImage())

        // The Dock's thumbnails put the caption's centre 25pt down; it is 45pt down.
        let looks = MissionControlCaptionLook.looks(in: image, origin: .zero, scale: 2, captions: [
            CaptionToMatch(key: "other", centre: CGPoint(x: 300, y: 25), barTop: 0, barBottom: 58,
                           maxWidth: 96, covers: "Desktop 2", name: "Fabric"),
        ])
        let look = try XCTUnwrap(looks["other"]?.plain)
        XCTAssertEqual(look.top, 33, accuracy: 0.01)
        XCTAssertEqual(look.frame.height, 24, accuracy: 0.01)
    }

    func testLinesTooThinForTextAreNotTakenForTheCaption() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 120, bitsPerComponent: 8, bytesPerRow: 800 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(cgColor(barColor))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 60))
        // The bar's lit bottom edge: one pixel, 56pt down, below the caption.
        context.setFillColor(cgColor(textColor))
        context.fill(CGRect(x: 0, y: 3.5, width: 400, height: 0.5))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(textColor),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Desktop 2", attributes: attributes))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: 300 - ink.midX, y: 10)  // baseline 50pt down
        CTLineDraw(line, context)
        let image = try XCTUnwrap(context.makeImage())

        let looks = MissionControlCaptionLook.looks(in: image, origin: .zero, scale: 2, captions: [
            CaptionToMatch(key: "edge", centre: CGPoint(x: 300, y: 45), barTop: 0, barBottom: 58,
                           maxWidth: 96, covers: "Desktop 2", name: "Fabric"),
        ])
        let look = try XCTUnwrap(looks["edge"]?.plain)
        XCTAssertEqual(look.top, 33, accuracy: 0.01)
        XCTAssertEqual(look.frame.height, 24, accuracy: 0.01)
    }

    func testCaptionsWithNoTextAreNotMatched() throws {
        XCTAssertNil(try matchSyntheticBar()["empty"])
    }

    // MARK: - Capture agreement

    /// A look whose caption image sits `top` points below the bar's top.
    private func look(top: CGFloat) throws -> NativeCaptionLook {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let variant = NativeCaptionLook.Variant(
            frame: CGRect(x: -43, y: top - 20, width: 86, height: 25), top: top, image: image)
        return NativeCaptionLook(plain: variant, current: variant, wasCurrent: false, summary: "")
    }

    func testACaptionsFirstCaptureIsUsedAtOnce() throws {
        let settled = NativeCaptionLook.settle(captured: try look(top: 7.5), held: nil, waiting: nil)
        XCTAssertEqual(settled.use?.plain?.top, 7.5)
        XCTAssertNil(settled.waiting)
    }

    func testACaptureAgreeingWithTheLookInUseReplacesIt() throws {
        let settled = NativeCaptionLook.settle(
            captured: try look(top: 8), held: try look(top: 7.5), waiting: try look(top: -1.5))
        XCTAssertEqual(settled.use?.plain?.top, 8)
        XCTAssertNil(settled.waiting)
    }

    /// One capture, taken as the bar began sliding up, put the captions 9pt high.
    func testACaptureMovingACaptionWaitsForASecondToAgree() throws {
        let held = try look(top: 7.5)
        let first = NativeCaptionLook.settle(captured: try look(top: -1.5), held: held, waiting: nil)
        XCTAssertNil(first.use)
        XCTAssertEqual(first.waiting?.plain?.top, -1.5)
        let second = NativeCaptionLook.settle(captured: try look(top: -1.25), held: held, waiting: first.waiting)
        XCTAssertEqual(second.use?.plain?.top, -1.25)
        XCTAssertNil(second.waiting)
    }

    func testCapturesThatAgreeWithNothingKeepWaiting() throws {
        let settled = NativeCaptionLook.settle(
            captured: try look(top: 3), held: try look(top: 7.5), waiting: try look(top: -1.5))
        XCTAssertNil(settled.use)
        XCTAssertEqual(settled.waiting?.plain?.top, 3)
    }

    // MARK: - Dock motion

    /// Each motion runs from 0 to 1 without turning back on the way, though some overshoot a little
    /// and settle back, as the Dock's do.
    func testTimedMotionsRunFromStartToEnd() {
        for timing in [DockMotion.open, DockMotion.close, DockMotion.closeExpanded, DockMotion.reverse] {
            XCTAssertEqual(timing.progress(at: 10, from: 10), 0)
            XCTAssertEqual(timing.progress(at: timing.end(from: 10) + 0.001, from: 10), 1)
            var last: CGFloat = 0
            for step in 0...100 {
                let progress = timing.progress(at: 10 + timing.end(from: 0) * Double(step) / 100, from: 10)
                if last < 1 {
                    XCTAssertGreaterThanOrEqual(progress, last - 0.001, "\(timing) goes back at step \(step)")
                }
                XCTAssertLessThan(progress, 1.02, "\(timing) overshoots at step \(step)")
                last = progress
            }
        }
    }

    func testASlidesKeyframesFollowItsCurve() {
        let slide = TimedSlide(timing: DockMotion.close, reference: 50, from: 0.2, to: 1)
        let frames = slide.keyframes(steps: 60)
        XCTAssertEqual(frames.count, 61)
        XCTAssertEqual(frames[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(frames[60], 1, accuracy: 1e-9)
        for step in 0...60 {
            let time = slide.start + slide.timing.duration * Double(step) / 60
            XCTAssertEqual(frames[step], slide.retraction(at: time), accuracy: 1e-6)
        }
    }

    func testThumbnailsMovingTogetherCountAsASidewaysShift() {
        let old = [CGPoint(x: 100, y: 130), CGPoint(x: 274, y: 130), CGPoint(x: 448, y: 130)]
        XCTAssertEqual(MissionControlLabels.uniformShift(from: old, to: old.map { CGPoint(x: $0.x - 8, y: $0.y) }), -8)
        XCTAssertEqual(MissionControlLabels.uniformShift(from: old, to: old), 0)
        // Growing thumbnails spread out instead.
        let spread = [CGPoint(x: 100, y: 130), CGPoint(x: 290, y: 130), CGPoint(x: 480, y: 130)]
        XCTAssertNil(MissionControlLabels.uniformShift(from: old, to: spread))
        XCTAssertNil(MissionControlLabels.uniformShift(from: old, to: Array(old.prefix(2))))
    }

    func testASidewaysShiftSlidesFromWhereTheLabelsWereToTheirNewPlaces() {
        let shift = TimedShift(timing: DockMotion.shift, reference: 10, from: 8)
        XCTAssertEqual(shift.offset(at: 10), 8)
        XCTAssertEqual(shift.offset(at: DockMotion.shift.end(from: 10)), 0, accuracy: 1e-9)
        let frames = shift.keyframes(steps: 20)
        XCTAssertEqual(frames.first, 8)
        XCTAssertEqual(frames.last ?? 1, 0, accuracy: 1e-9)
        // The Dock's slide overshoots a little and settles back.
        XCTAssertGreaterThan(frames.min() ?? 0, -8 * 0.06)
    }

    func testALabelsMoveRunsFromItsOffsetToWhereItIsPlaced() {
        let move = TimedMove(timing: DockMotion.expand, reference: 10, from: CGVector(dx: -40, dy: -112))
        let frames = move.keyframes(steps: 20)
        XCTAssertEqual(frames.first, CGVector(dx: -40, dy: -112))
        XCTAssertEqual(frames.last?.dx ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(frames.last?.dy ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(move.start, 10 + DockMotion.expand.delay, accuracy: 1e-9)
        XCTAssertFalse(move.isFinished(at: move.start))
        XCTAssertTrue(move.isFinished(at: DockMotion.expand.end(from: 10)))
    }

    func testCubicBezierMatchesKnownCurves() {
        // cubic-bezier(0, 0, 1, 1) is a straight line; ease-in-out is symmetric about the middle.
        XCTAssertEqual(CubicBezier(0, 0, 1, 1).value(at: 0.3), 0.3, accuracy: 0.0001)
        XCTAssertEqual(CubicBezier(0.42, 0, 0.58, 1).value(at: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(CubicBezier(0.42, 0, 0.58, 1).value(at: 0.2) + CubicBezier(0.42, 0, 0.58, 1).value(at: 0.8),
                       1, accuracy: 0.0001)
        XCTAssertEqual(CubicBezier(0.42, 0, 0.58, 1).value(at: -1), 0)
        XCTAssertEqual(CubicBezier(0.42, 0, 0.58, 1).value(at: 2), 1)
    }

    func testAReplayedOpenSlidesTheBarIn() {
        let open = TimedSlide(timing: DockMotion.open, reference: 100, from: 1, to: 0)
        XCTAssertEqual(open.retraction(at: 100), 1)
        XCTAssertEqual(open.retraction(at: DockMotion.open.end(from: 100)), 0, accuracy: 1e-9)
        XCTAssertFalse(open.isFinished(at: 100.1))
        XCTAssertTrue(open.isFinished(at: DockMotion.open.end(from: 100)))
        let halfway = open.retraction(at: 100 + DockMotion.open.delay + DockMotion.open.duration / 2)
        XCTAssertGreaterThan(halfway, 0.1)
        XCTAssertLessThan(halfway, 0.9)
    }

    func testTheLiftingSpeedIsMeasuredOverTheLastFewFrames() {
        let samples: [(time: TimeInterval, retraction: CGFloat)] = [(0, 1), (0.02, 0.9), (0.04, 0.8), (0.06, 0.7)]
        XCTAssertEqual(MissionControlSwipeTracker.velocity(of: samples), -5, accuracy: 0.0001)
        XCTAssertEqual(MissionControlSwipeTracker.velocity(of: [(0, 1)]), 0)
    }

    // MARK: - Desktops added and removed

    /// Measured on a 2560-point screen: 14 thumbnails 145 wide every 174 from 149; 15 every 162 from 146.
    func testAddingADesktopNarrowsAStripThatFillsTheScreen() {
        let centres = MissionControlLabels.predictedCentres(
            count: 15, shown: 14, screenMinX: 0, screenWidth: 2560, width: 145, spacing: 174)
        XCTAssertEqual(centres.count, 15)
        XCTAssertEqual(centres[0], 146, accuracy: 3)
        XCTAssertEqual(centres[1] - centres[0], 162, accuracy: 1)
        XCTAssertEqual(centres[14], 2414, accuracy: 3)
    }

    func testRemovingADesktopWidensAStripThatFillsTheScreen() {
        let centres = MissionControlLabels.predictedCentres(
            count: 14, shown: 15, screenMinX: 0, screenWidth: 2560, width: 135, spacing: 162)
        XCTAssertEqual(centres.count, 14)
        XCTAssertEqual(centres[0], 149, accuracy: 3)
        XCTAssertEqual(centres[1] - centres[0], 174, accuracy: 1)
    }

    func testAFewThumbnailsKeepTheirSizeAndStayCentred() {
        let centres = MissionControlLabels.predictedCentres(
            count: 4, shown: 3, screenMinX: 2560, screenWidth: 1728, width: 140, spacing: 170)
        XCTAssertEqual(centres.count, 4)
        XCTAssertEqual(centres[1] - centres[0], 170, accuracy: 0.01)
        XCTAssertEqual((centres[0] + centres[3]) / 2, 2560 + 864, accuracy: 0.01)
    }

    // MARK: - Dragging a thumbnail

    // Filmed on macOS 26.7. Each middle is the pointer, less the Dock's hold on the distance from the
    // picked-up thumbnail's middle as the drag started.

    /// 14 thumbnails 174 points apart; held 2 points off the middle.
    private let fourteen: [CGFloat] = (0..<14).map { 149 + 174 * CGFloat($0) }
    private let heldClose = 2 * MissionControlLabels.dragHold

    /// 15 thumbnails 162 points apart; held 52 points off the middle.
    private let fifteen: [CGFloat] = (0..<15).map { 146 + 162 * CGFloat($0) }
    private let heldFar = 52 * MissionControlLabels.dragHold

    func testDraggedRightTakesTheNextPlaceOnlyOncePastTheCrossing() {
        XCTAssertEqual(MissionControlLabels.dragGap(from: 2, centres: fourteen, middleX: 698.5 - heldClose), 2)
        XCTAssertEqual(MissionControlLabels.dragGap(from: 2, centres: fourteen, middleX: 700.5 - heldClose), 3)
        XCTAssertEqual(MissionControlLabels.dragGap(from: 2, centres: fifteen, middleX: 700 - heldFar), 2)
        XCTAssertEqual(MissionControlLabels.dragGap(from: 2, centres: fifteen, middleX: 701 - heldFar), 3)
    }

    func testDraggedLeftTakesThePlaceBeforeOnlyOnceBackPastTheCrossing() {
        XCTAssertEqual(MissionControlLabels.dragGap(from: 3, centres: fourteen, middleX: 526.5 - heldClose), 3)
        XCTAssertEqual(MissionControlLabels.dragGap(from: 3, centres: fourteen, middleX: 523.5 - heldClose), 2)
        XCTAssertEqual(MissionControlLabels.dragGap(from: 3, centres: fifteen, middleX: 541 - heldFar), 3)
        XCTAssertEqual(MissionControlLabels.dragGap(from: 3, centres: fifteen, middleX: 538 - heldFar), 2)
    }

    func testBarCentringAsADragStartsCarriesThePlaceAlong() {
        // Picked up from the fourth place with the bar hover-shifted: centred under the still pointer,
        // the dragged thumbnail is past the fifth, which the Dock moves aside at once.
        XCTAssertEqual(MissionControlLabels.dragGap(from: 3, centres: fifteen, middleX: 926 - heldFar), 4)
    }

    func testDraggedThumbnailPassesSeveralPlacesInOneMove() {
        XCTAssertEqual(MissionControlLabels.dragGap(from: 2, centres: fourteen, middleX: 1400), 7)
        XCTAssertEqual(MissionControlLabels.dragGap(from: 4, centres: fourteen, middleX: 100), 0)
    }

    // MARK: - Watching the captions during a drag

    /// Picked up from the fourth place of 15, with the place it would go now the fifth.
    private func watched(_ middles: [CGFloat], gap: Int = 4, moving: Set<Int> = []) -> (gap: Int, gone: CGFloat?)? {
        MissionControlLabels.watchedGap(middles: middles, slots: fifteen, origin: 3, gap: gap, moving: moving)
    }

    /// The captions where the thumbnails rest, the dragged one's place empty.
    private func resting(gap: Int = 4) -> [CGFloat] {
        fifteen.indices.filter { $0 != gap }.map { fifteen[$0] }
    }

    func testCaptionsAtRestLeaveThePlaceAsItWas() {
        XCTAssertEqual(watched(resting())?.gap, 4)
        XCTAssertNil(watched(resting())?.gone ?? nil)
    }

    func testACaptionLeavingItsPlaceMovesThePlaceThere() throws {
        var middles = resting()
        middles[4] -= 20 // the sixth place's caption, on its way to the fifth
        let seen = try XCTUnwrap(watched(middles))
        XCTAssertEqual(seen.gap, 5)
        XCTAssertEqual(try XCTUnwrap(seen.gone), 20 / 162, accuracy: 0.001)
    }

    func testCaptionsLeavingSeveralPlacesMoveThePlacePastThemAll() {
        var middles = resting()
        for index in 4...6 { middles[index] -= 10 }
        XCTAssertEqual(watched(middles)?.gap, 7)
    }

    func testCaptionsLeavingTowardsTheStartMoveThePlaceBack() {
        var middles = resting()
        middles[3] += 30 // the fourth place's caption, on its way to the fifth
        XCTAssertEqual(watched(middles)?.gap, 3)
    }

    func testACaptionAlreadyMovingIsNotTakenForANewMove() {
        // The place was just moved to the fifth: the caption first at the fifth is still on its way to
        // the fourth, and the one from the fourth place, picked up, is the dragged one.
        var middles = resting()
        middles.remove(at: 3)
        middles.append(fifteen[4] - 40)
        XCTAssertEqual(watched(middles.sorted(), moving: [4])?.gap, 4)
    }

    func testASlidingBarTellsNothing() {
        XCTAssertNil(watched(resting().map { $0 + 30 }))
    }

    func testCaptionsGoneBothWaysTellNothing() {
        var middles = resting()
        middles.remove(at: 8)
        middles.remove(at: 1)
        XCTAssertNil(watched(middles))
    }

    func testPlacesAreFittedPastAThumbnailOffItsPlace() throws {
        var middles = fifteen
        middles[3] = 700
        let slots = try XCTUnwrap(MissionControlLabels.slotCentres(middles))
        for (fitted, place) in zip(slots, fifteen) { XCTAssertEqual(fitted, place, accuracy: 0.001) }
    }

    func testMakingRoomIsReckonedFromHowFarItHasGone() {
        let timing = DockMotion.makeRoom
        let time = timing.time(toReach: 0.5)
        XCTAssertEqual(timing.progress(at: time, from: 0), 0.5, accuracy: 0.001)
    }
}
