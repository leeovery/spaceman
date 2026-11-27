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

    private var syntheticCaptions: [CaptionToMatch] {
        [
            CaptionToMatch(key: "current", centre: CGPoint(x: 100, y: 20),
                           barTop: 0, barBottom: 40, maxWidth: 96, covers: "Desktop 1",
                           name: "Personal"),
            CaptionToMatch(key: "other", centre: CGPoint(x: 300, y: 20),
                           barTop: 0, barBottom: 40, maxWidth: 96, covers: "Desktop 2",
                           name: "Fabric"),
            CaptionToMatch(key: "empty", centre: CGPoint(x: 200, y: 20),
                           barTop: 0, barBottom: 40, maxWidth: 96, covers: "Desktop 3",
                           name: "Nothing here"),
        ]
    }

    private func matchSyntheticBar() throws -> [String: NativeCaptionLook] {
        MissionControlCaptionLook.looks(in: try syntheticBar(), origin: .zero, scale: 2, captions: syntheticCaptions)
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

    /// A 2x capture of a 400x80pt bar with a bright sliver 7pt tall, 62 to 69pt down, as a capture taken while
    /// magnified thumbnails resize can find where a caption should be; and, with `text`, "Desktop 2" above it
    /// on a baseline 50pt down.
    private func barWithSliver(text: Bool) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 160, bitsPerComponent: 8, bytesPerRow: 800 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(cgColor(barColor))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 80))
        context.setFillColor(cgColor(textColor))
        context.fill(CGRect(x: 270, y: 11, width: 60, height: 7))
        if text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(textColor),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "Desktop 2", attributes: attributes))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: 300 - ink.midX, y: 30)
            CTLineDraw(line, context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private let sliverCaption = CaptionToMatch(
        key: "sliver", centre: CGPoint(x: 300, y: 45), barTop: 0, barBottom: 78, maxWidth: 96, covers: "Desktop 2",
        name: "Fabric")

    func testASliverShorterThanTheCaptionsTextCouldBeIsNoLook() throws {
        let matches = MissionControlCaptionLook.matches(
            in: try barWithSliver(text: false), origin: .zero, scale: 2, captions: [sliverCaption])
        XCTAssertNil(matches.looks["sliver"])
        XCTAssertTrue(try XCTUnwrap(matches.misses["sliver"]).hasPrefix("no text"))
    }

    /// A caption macOS truncates can lose the descenders its full title has.
    func testACaptionWithoutItsDescendersIsStillMatched() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 120, bitsPerComponent: 8, bytesPerRow: 800 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(cgColor(barColor))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 60))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(textColor),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Desktop 2", attributes: attributes))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: 300 - ink.midX, y: 10)  // baseline 50pt down
        CTLineDraw(line, context)
        context.setFillColor(cgColor(barColor))
        context.fill(CGRect(x: 200, y: 0, width: 200, height: 10))
        let image = try XCTUnwrap(context.makeImage())
        let looks = MissionControlCaptionLook.looks(in: image, origin: .zero, scale: 2, captions: [
            CaptionToMatch(key: "cut", centre: CGPoint(x: 300, y: 45), barTop: 0, barBottom: 58, maxWidth: 96,
                           covers: "Desktop 2", name: "Fabric"),
        ])
        XCTAssertNotNil(looks["cut"])
    }

    func testASliverBelowTheCaptionIsPassedOver() throws {
        let looks = MissionControlCaptionLook.looks(
            in: try barWithSliver(text: true), origin: .zero, scale: 2, captions: [sliverCaption])
        let look = try XCTUnwrap(looks["sliver"]?.plain)
        XCTAssertEqual(look.top, 33, accuracy: 0.01)
        XCTAssertEqual(look.frame.height, 24, accuracy: 0.01)
    }

    func testCaptionsWithNoTextAreNotMatched() throws {
        XCTAssertNil(try matchSyntheticBar()["empty"])
    }

    func testAMissedCaptionSaysWhyAndAMatchedOneHasNoMiss() throws {
        let matches = MissionControlCaptionLook.matches(
            in: try syntheticBar(), origin: .zero, scale: 2, captions: syntheticCaptions)
        XCTAssertEqual(Set(matches.looks.keys), ["current", "other"])
        XCTAssertEqual(Array(matches.misses.keys), ["empty"])
        XCTAssertEqual(matches.misses["empty"], "contrast 0, not over 40")
    }

    // MARK: - Capture agreement

    /// A look whose caption image sits `top` points below the bar's top.
    private func look(top: CGFloat) throws -> NativeCaptionLook {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let variant = NativeCaptionLook.Variant(
            frame: CGRect(x: -43, y: top - 20, width: 86, height: 25), top: top, image: image, baseline: 17.5)
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

    // MARK: - Caption looks

    private func caption(_ number: Int, _ name: String) -> Caption {
        Caption(
            centre: CGPoint(x: CGFloat(number) * 200, y: 30), maxWidth: 180, index: number - 1,
            covers: "Desktop \(number)", name: name, colorHex: nil, spaceID: "\(number)")
    }

    /// A bar on `screen`, `retraction` of its height above its place at rest.
    private func bar(_ screen: CGRect, height: CGFloat = 40, retraction: CGFloat = 0, _ captions: [Caption])
        -> BarLayout {
        let lift = retraction * height
        return BarLayout(
            bar: nil, firstButton: nil,
            frame: CGRect(x: screen.minX, y: screen.minY - lift, width: screen.width, height: height),
            firstButtonX: nil, screen: screen, displayID: 1,
            captions: captions.map { caption in
                var lifted = caption
                lifted.centre.y -= lift
                return lifted
            })
    }

    private var mail: Caption { caption(1, "Mail") }
    private var code: Caption { caption(2, "Code") }
    private var mainBar: BarLayout { bar(primary, [mail, code]) }
    private var builtInBar: BarLayout { bar(builtIn, height: 72, [caption(1, "Notes")]) }
    private var primaryKey: String { CaptionLooks.screenKey(primary) }
    private var builtInKey: String { CaptionLooks.screenKey(builtIn) }

    private func found(_ captions: [Caption], on bar: BarLayout) throws -> [String: NativeCaptionLook] {
        var found: [String: NativeCaptionLook] = [:]
        for caption in captions { found[CaptionLooks.keys(bar: bar, caption: caption).exact] = try look(top: 7.5) }
        return found
    }

    func testAKeptCaptureIsFoundEveryWayALabelLooksForIt() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar], attempt: 1)
        let result = CaptionLooks.Result(found: try found([mail, code], on: mainBar))
        XCTAssertEqual(looks.finish(capture, result, moved: false), .kept)
        XCTAssertEqual(looks.look(for: mail, on: bar(primary, retraction: 0.5, [mail]))?.exact, true)
        let moved = try XCTUnwrap(looks.look(for: caption(3, "Mail"), on: mainBar))
        XCTAssertFalse(moved.exact)
    }

    /// A names-row look drawn over a thumbnail's caption showed larger text on a darker plate.
    func testALookCapturedWithTheBarAtAnotherHeightIsNeverUsed() throws {
        var looks = CaptionLooks()
        _ = looks.finish(looks.capture(of: [mainBar], attempt: 1),
                         CaptionLooks.Result(found: try found([mail, code], on: mainBar)), moved: false)
        let expanded = bar(primary, height: 146, [mail, caption(3, "Mail")])
        XCTAssertNil(looks.look(for: mail, on: expanded))
        XCTAssertNil(looks.look(for: caption(3, "Mail"), on: expanded))
        XCTAssertTrue(looks.lookMayArrive(for: mail, on: expanded))
    }

    func testAKeptCaptureRecordsTheBackgroundItWasCapturedOver() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar], attempt: 1)
        let result = CaptionLooks.Result(
            found: try found([mail, code], on: mainBar), backgrounds: [primaryKey: "hills"])
        _ = looks.finish(capture, result, moved: false)
        XCTAssertEqual(looks.backgrounds, [primaryKey: "hills"])
    }

    func testACaptureTheBarsMovedUnderTakesNothing() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar], attempt: 1)
        let result = CaptionLooks.Result(found: try found([mail], on: mainBar), backgrounds: [primaryKey: "hills"])
        XCTAssertEqual(looks.finish(capture, result, moved: true), .moved)
        XCTAssertEqual(looks.backgrounds, [:])
        XCTAssertNil(looks.look(for: mail, on: mainBar))
        XCTAssertTrue(looks.lookMayArrive(for: code, on: mainBar))
    }

    /// The bar of names is shot moments before the pointer enters it and the Dock grows it: the bars move while the
    /// capture goes on to the next screen. Every names-row capture of the run filmed came to nothing that way, so
    /// none was ever kept on disk, and the first session after a launch showed macOS's captions.
    func testOnlyScreensShotAfterTheBarsBeganToMoveAreCaughtMoving() {
        let result = CaptionLooks.Result(taken: [primaryKey: 10.0, builtInKey: 10.2])
        XCTAssertEqual(CaptionLooks.screensShotMoving(result, movedAt: 10.1), [builtInKey])
        XCTAssertEqual(CaptionLooks.screensShotMoving(result, movedAt: 9.9), [primaryKey, builtInKey])
        XCTAssertEqual(CaptionLooks.screensShotMoving(result, movedAt: nil), [])
    }

    func testAScreenShotBeforeTheBarsMovedIsKeptAndTheOtherAskedAboutAgain() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar, builtInBar], attempt: 1)
        var found = try found([mail, code], on: mainBar)
        found.merge(try self.found([caption(1, "Notes")], on: builtInBar)) { $1 }
        let result = CaptionLooks.Result(found: found, backgrounds: [primaryKey: "hills", builtInKey: "sea"])
        XCTAssertEqual(looks.finish(capture, result, movedOn: [builtInKey]), .retry)
        XCTAssertNotNil(looks.look(for: mail, on: mainBar))
        XCTAssertNil(looks.look(for: caption(1, "Notes"), on: builtInBar))
        XCTAssertTrue(looks.lookMayArrive(for: caption(1, "Notes"), on: builtInBar))
        XCTAssertEqual(looks.backgrounds, [primaryKey: "hills"])
        XCTAssertNotNil(looks.screenLooks(primaryKey))
        XCTAssertNil(looks.screenLooks(builtInKey))
        var again = CaptionLooks()
        XCTAssertEqual(again.finish(again.capture(of: [mainBar, builtInBar], attempt: 1), result,
                                    movedOn: [primaryKey, builtInKey]), .moved)
    }

    func testTheLastAttemptTheBarsMovedUnderSpendsEveryCaption() {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar], attempt: CaptionLooks.attemptLimit)
        _ = looks.finish(capture, CaptionLooks.Result(), moved: true)
        XCTAssertFalse(looks.lookMayArrive(for: mail, on: mainBar))
        XCTAssertFalse(looks.lookMayArrive(for: code, on: mainBar))
    }

    /// The draw looks a caption up on the bar as it is, perhaps still sliding in; the capture asked
    /// about it on the bar at rest. A capture of the bar at one height says nothing of it at another.
    func testACaptionACaptureFoundNoLookForIsSpentWhereverTheBarIsAtThatHeight() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [bar(primary, retraction: 0.2, [mail, code])], attempt: 1)
        XCTAssertEqual(looks.finish(capture, CaptionLooks.Result(found: try found([mail], on: mainBar)), moved: false),
                       .kept)
        XCTAssertFalse(looks.lookMayArrive(for: code, on: bar(primary, retraction: 0.7, [mail, code])))
        XCTAssertTrue(looks.lookMayArrive(for: code, on: bar(primary, height: 146, [mail, code])))
        XCTAssertTrue(looks.lookMayArrive(for: caption(3, "Docs"), on: mainBar))
    }

    /// A capture taken as the bar began to slide away put the captions 9pt high.
    func testACaptureMovingACaptionKeepsTheLookInUseUntilAnotherAgrees() throws {
        var looks = CaptionLooks()
        _ = looks.finish(looks.capture(of: [mainBar], attempt: 1),
                         CaptionLooks.Result(found: try found([mail, code], on: mainBar)), moved: false)
        let mailKey = CaptionLooks.keys(bar: mainBar, caption: mail).exact
        let moved = CaptionLooks.Result(found: [mailKey: try look(top: -1.5)])
        XCTAssertEqual(looks.finish(looks.capture(of: [bar(primary, [mail])], attempt: 2), moved, moved: false),
                       .retry)
        XCTAssertEqual(looks.look(for: mail, on: mainBar)?.look.plain?.top, 7.5)
        XCTAssertEqual(looks.look(for: caption(3, "Mail"), on: mainBar)?.look.plain?.top, 7.5)
        let agreeing = CaptionLooks.Result(found: [mailKey: try look(top: -1.25)])
        XCTAssertEqual(looks.finish(looks.capture(of: [bar(primary, [mail])], attempt: 3), agreeing, moved: false),
                       .kept)
        XCTAssertEqual(looks.look(for: mail, on: mainBar)?.look.plain?.top, -1.25)
    }

    func testAScreenACaptureFailedOnIsAskedAboutAgain() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar, builtInBar], attempt: 1)
        let result = CaptionLooks.Result(
            found: try found([mail, code], on: mainBar), failed: [builtInKey],
            backgrounds: [primaryKey: "hills", builtInKey: "sea"])
        XCTAssertEqual(looks.finish(capture, result, moved: false), .retry)
        XCTAssertTrue(looks.lookMayArrive(for: caption(1, "Notes"), on: builtInBar))
        XCTAssertEqual(looks.backgrounds, [primaryKey: "hills"])
    }

    func testAScreenTheLastAttemptFailedOnIsSpent() {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [builtInBar], attempt: CaptionLooks.attemptLimit)
        XCTAssertEqual(looks.finish(capture, CaptionLooks.Result(failed: [builtInKey]), moved: false), .kept)
        XCTAssertFalse(looks.lookMayArrive(for: caption(1, "Notes"), on: builtInBar))
    }

    func testACaptureFromAnEarlierSessionIsIgnored() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar], attempt: CaptionLooks.attemptLimit)
        looks.beginSession()
        let result = CaptionLooks.Result(found: try found([mail], on: mainBar), backgrounds: [primaryKey: "hills"])
        XCTAssertEqual(looks.finish(capture, result, moved: false), .stale)
        XCTAssertNil(looks.look(for: mail, on: mainBar))
        XCTAssertTrue(looks.lookMayArrive(for: code, on: mainBar))
        XCTAssertEqual(looks.backgrounds, [:])
    }

    func testANewSessionWaitsForLooksAgain() {
        var looks = CaptionLooks()
        _ = looks.finish(looks.capture(of: [mainBar], attempt: 1), CaptionLooks.Result(), moved: false)
        XCTAssertFalse(looks.lookMayArrive(for: mail, on: mainBar))
        looks.beginSession()
        XCTAssertTrue(looks.lookMayArrive(for: mail, on: mainBar))
    }

    func testACaptionWaitsForItsLookOnlySoLongAtRest() {
        var looks = CaptionLooks()
        looks.noteBars(resting: true, at: 5)
        XCTAssertTrue(looks.lookMayArrive(for: mail, on: mainBar))
        looks.noteBars(resting: true, at: 6.25)
        XCTAssertTrue(looks.lookMayArrive(for: mail, on: mainBar))
        XCTAssertTrue(looks.lookMayArrive(for: code, on: mainBar))
        looks.noteBars(resting: true, at: 5 + CaptionLooks.lookWait)
        XCTAssertFalse(looks.lookMayArrive(for: mail, on: mainBar))
        XCTAssertTrue(looks.lookMayArrive(for: code, on: mainBar))
    }

    /// A swipe held part way, or Mission Control closing, moves the captions: the fallback must not
    /// switch in over them as they go.
    func testACaptionWaitsForItsLookOnlyWhileTheBarsRest() {
        var looks = CaptionLooks()
        looks.noteBars(resting: true, at: 0)
        looks.noteBars(resting: true, at: 1)
        XCTAssertTrue(looks.lookMayArrive(for: mail, on: mainBar))
        looks.noteBars(resting: false, at: 1.1)
        looks.noteBars(resting: false, at: 9)
        XCTAssertTrue(looks.lookMayArrive(for: mail, on: mainBar))
        looks.noteBars(resting: true, at: 10)
        looks.noteBars(resting: true, at: 11.25)
        XCTAssertTrue(looks.lookMayArrive(for: mail, on: mainBar))
        looks.noteBars(resting: true, at: 11.5)
        XCTAssertFalse(looks.lookMayArrive(for: mail, on: mainBar))
    }

    // MARK: - Looks over another background

    private let captured = ["0.0,0.0": "A|2560.0x1440.0@2.0|NSAppearanceNameDarkAqua|false|hills.heic|",
                            "2560.0,904.0": "B|1728.0x1117.0@2.0|NSAppearanceNameDarkAqua|false|sea.heic|"]

    func testTheSameBackgroundsKeepEveryScreensLooks() {
        XCTAssertEqual(CaptionLooks.staleScreens(captured: captured, current: captured), [])
    }

    func testAChangedBackgroundMakesOnlyThatScreensLooksStale() {
        var current = captured
        current["2560.0,904.0"] = "B|1728.0x1117.0@2.0|NSAppearanceNameDarkAqua|false|desert.heic|"
        XCTAssertEqual(CaptionLooks.staleScreens(captured: captured, current: current), ["2560.0,904.0"])
    }

    func testADisconnectedScreenKeepsItsLooks() {
        let current = ["0.0,0.0": captured["0.0,0.0"] ?? ""]
        XCTAssertEqual(CaptionLooks.staleScreens(captured: captured, current: current), [])
    }

    func testDroppingAScreensLooksKeepsTheOtherScreens() {
        let mainKeys = CaptionLooks.keys(bar: mainBar, caption: mail)
        let builtInKeys = CaptionLooks.keys(bar: builtInBar, caption: caption(1, "Notes"))
        let entries = [mainKeys.exact: 1, mainKeys.name: 2, builtInKeys.exact: 3, builtInKeys.name: 4]
        XCTAssertEqual(Set(CaptionLooks.dropping(entries, on: [builtInKeys.screen]).values), [1, 2])
    }

    func testLooksCapturedOverAnotherBackgroundAreDropped() throws {
        var looks = CaptionLooks()
        let capture = looks.capture(of: [mainBar, builtInBar], attempt: 1)
        let result = CaptionLooks.Result(
            found: try found([mail, code], on: mainBar)
                .merging(try found([caption(1, "Notes")], on: builtInBar)) { $1 },
            backgrounds: [primaryKey: "hills", builtInKey: "sea"])
        _ = looks.finish(capture, result, moved: false)
        looks.beginSession()
        let current = [primaryKey: "hills", builtInKey: "desert"]
        XCTAssertEqual(looks.dropLooks(capturedOver: current), 1)
        XCTAssertNotNil(looks.look(for: mail, on: mainBar))
        XCTAssertNil(looks.look(for: caption(1, "Notes"), on: builtInBar))
        XCTAssertEqual(looks.backgrounds, [primaryKey: "hills"])
    }

    /// A pattern wallpaper's fill colour describes itself with its address, different each time it is read.
    func testAFillColourIsDescribedTheSameEachTime() {
        let first = CaptionLooks.describe(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        XCTAssertEqual(first, CaptionLooks.describe(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)))
        XCTAssertEqual(first, "0.200 0.400 0.600 1.000")
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

    // MARK: - Which spaces get a label

    func testOnlySpaceColorsLabelsUnnamedSpaces() {
        XCTAssertTrue(MissionControlLabelStyle.spaceColors.labelsUnnamed)
        XCTAssertFalse(MissionControlLabelStyle.nativeLook.labelsUnnamed)
    }

    /// Mail, named in red; a space with only a colour; and one with no stored entry.
    private let storedNames = [
        "11": SpaceNameInfo(spaceNum: 1, spaceName: "Mail", spaceLabel: "1", colorHex: "FF0000"),
        "12": SpaceNameInfo(spaceNum: 2, spaceName: SpaceObserver.unnamedSpaceName, spaceLabel: "2",
                            colorHex: "00FF00"),
    ]

    private func thumbnails(_ titles: [String], spacing: CGFloat = 100) -> [AX.Button] {
        let element = AXUIElementCreateApplication(getpid())
        return titles.indices.map { index in
            (element, CGRect(x: CGFloat(index + 1) * spacing, y: 0, width: 80, height: 24), titles[index])
        }
    }

    private func matchedCaptions(
        labelsUnnamed: Bool, titles: [String] = ["Desktop 1", "Desktop 2", "Desktop 3"]
    ) -> [Caption] {
        MissionControlLabels.dockCaptions(
            thumbnails(titles), spaceIDs: ["11", "12", "13"], labelsUnnamed: labelsUnnamed, storedNames: storedNames
        ).captions
    }

    func testInSpaceColorsAnUnnamedSpaceIsLabelledWithItsCaptionAndColour() throws {
        let caption = try XCTUnwrap(matchedCaptions(labelsUnnamed: true).first { $0.spaceID == "12" })
        XCTAssertEqual(caption.name, "Desktop 2")
        XCTAssertEqual(caption.covers, "Desktop 2")
        XCTAssertEqual(caption.colorHex, "00FF00")
    }

    func testInSpaceColorsASpaceWithNoEntryIsLabelledWithItsCaptionAndNoColour() throws {
        let caption = try XCTUnwrap(matchedCaptions(labelsUnnamed: true).first { $0.spaceID == "13" })
        XCTAssertEqual(caption.name, "Desktop 3")
        XCTAssertNil(caption.colorHex)
    }

    func testAnUnnamedSpaceWithNoCaptionTitleGetsNoLabel() {
        let captions = matchedCaptions(labelsUnnamed: true, titles: ["Desktop 1", "", "Desktop 3"])
        XCTAssertEqual(captions.map(\.spaceID), ["11", "13"])
    }

    func testAnEmptyNameCountsAsUnnamed() {
        let named = ["1": SpaceNameInfo(spaceNum: 1, spaceName: "", spaceLabel: "1")]
        let match = { (labelsUnnamed: Bool) in
            MissionControlLabels.dockCaptions(
                self.thumbnails(["Desktop 1"]), spaceIDs: ["1"], labelsUnnamed: labelsUnnamed, storedNames: named
            ).captions
        }
        XCTAssertEqual(match(true).map(\.name), ["Desktop 1"])
        XCTAssertTrue(match(false).isEmpty)
    }

    func testInTheNativeLookUnnamedSpacesKeepTheirNativeCaptions() {
        XCTAssertEqual(matchedCaptions(labelsUnnamed: false).map(\.spaceID), ["11"])
    }

    func testANamedSpaceShowsItsNameInEitherStyle() throws {
        for labelsUnnamed in [true, false] {
            let caption = try XCTUnwrap(matchedCaptions(labelsUnnamed: labelsUnnamed).first { $0.spaceID == "11" })
            XCTAssertEqual(caption.name, "Mail")
            XCTAssertEqual(caption.covers, "Desktop 1")
            XCTAssertEqual(caption.colorHex, "FF0000")
        }
    }

    /// Two full-screen windows of one app share a title: each caption knows its own thumbnail.
    func testCaptionsKnowTheirThumbnailsWhenTitlesRepeat() {
        let captions = matchedCaptions(labelsUnnamed: true, titles: ["Safari", "Safari", "Desktop 3"])
        XCTAssertEqual(captions.map(\.index), [0, 1, 2])
        XCTAssertEqual(captions.map(\.spaceID), ["11", "12", "13"])
    }

    /// A Dock bar of `titles` showing `spaceIDs`, its captions matched in the native look.
    private func dockBar(
        _ titles: [String], spaceIDs: [String], labelsUnnamed: Bool = false, spacing: CGFloat = 100
    ) -> BarLayout {
        let found = thumbnails(titles, spacing: spacing)
        return BarLayout(
            bar: nil, firstButton: nil, frame: CGRect(x: 0, y: 0, width: 2560, height: 40), firstButtonX: nil,
            screen: primary, displayID: 1,
            captions: MissionControlLabels.dockCaptions(
                found, spaceIDs: spaceIDs, labelsUnnamed: labelsUnnamed, storedNames: storedNames).captions,
            buttons: found.map { ($0.element, $0.title, $0.frame) }, spaceIDs: spaceIDs)
    }

    func testAKeptLayoutIsRematchedInTheNewSessionsStyle() {
        let native = dockBar(["Desktop 1", "Desktop 2", "Desktop 3"], spaceIDs: ["11", "12", "13"])
        XCTAssertEqual(native.captions.map(\.spaceID), ["11"])
        let colours = native.rematched(labelsUnnamed: true, storedNames: storedNames)
        XCTAssertEqual(colours.captions.map(\.name), ["Mail", "Desktop 2", "Desktop 3"])
        XCTAssertEqual(colours.captions.map(\.centre), matchedCaptions(labelsUnnamed: true).map(\.centre))
        XCTAssertEqual(colours.rematched(labelsUnnamed: false, storedNames: storedNames).captions.map(\.spaceID),
                       ["11"])
    }

    func testADraggedThumbnailIsKnownByItsPlaceNotItsTitle() {
        let bar = dockBar(["Safari", "Safari", "Desktop 3"], spaceIDs: ["11", "12", "13"])
        let drag = ThumbnailDrag(bar: bar, origin: 1, grabOffset: 0, at: 0)
        XCTAssertEqual(drag.spaceID, "12")
        XCTAssertEqual(drag.places, ["11": 0, "12": 1, "13": 2])
    }

    /// Dragging the unnamed first thumbnail to the end leaves the named ones in their order, but the
    /// thumbnails are reordered: the labels follow the Dock, not the places reckoned for the drag.
    func testADropReordersByEveryThumbnailNotOnlyTheLabelledOnes() {
        let titles = ["Desktop 1", "Desktop 2", "Desktop 3"]
        let picked = dockBar(titles, spaceIDs: ["13", "11", "12"])
        let drag = ThumbnailDrag(bar: picked, origin: 0, grabOffset: 0, at: 0)
        let dropped = dockBar(titles, spaceIDs: ["11", "12", "13"])
        XCTAssertEqual(dropped.captions.map(\.spaceID), picked.captions.map(\.spaceID))
        XCTAssertTrue(drag.keepsOrder(of: picked))
        XCTAssertFalse(drag.keepsOrder(of: dropped))
        XCTAssertNil(drag.place(of: "11", in: dropped))
    }

    private func addReflow(spacesBefore: [String]) -> Reflow {
        Reflow(screen: primary, timing: DockMotion.add, reference: 5, from: ["1": CGPoint(x: 300, y: 30)],
               spacesBefore: spacesBefore, count: 2)
    }

    func testADesktopAddedHasNoLabelUntilTheOthersAreInPlace() throws {
        let reflow = addReflow(spacesBefore: ["1"])
        XCTAssertTrue(reflow.holds(caption(2, "Code")))
        XCTAssertFalse(reflow.holds(caption(1, "Mail")))
        let move = try XCTUnwrap(reflow.move(of: caption(1, "Mail")))
        XCTAssertEqual(move, TimedMove(timing: DockMotion.add, reference: 5, from: CGVector(dx: 100, dy: 0)))
    }

    /// A bar read while macOS and the Dock disagreed on its spaces: no label is new, so none waits.
    func testNoLabelWaitsWhenTheSpacesBeforeWereUnknown() {
        let reflow = addReflow(spacesBefore: [])
        XCTAssertFalse(reflow.holds(caption(2, "Code")))
        XCTAssertNil(reflow.move(of: caption(2, "Code")))
    }

    func testAPredictedRemovalMovesTheLabelsAfterItAPlaceAlong() throws {
        let before = bar(primary, [caption(1, "Mail"), caption(2, "Code"), caption(3, "Notes")])
        let predicted = try XCTUnwrap(MissionControlLabels.predictedLayout(before, centres: [500, 700], removing: 0))
        XCTAssertEqual(predicted.captions.map(\.spaceID), ["2", "3"])
        XCTAssertEqual(predicted.captions.map(\.index), [0, 1])
        XCTAssertEqual(predicted.captions.map(\.centre.x), [500, 700])
        XCTAssertTrue(predicted.spaceIDs.isEmpty)
    }

    /// The last thumbnail removed from a bar measured without it already: its labels' places don't fit.
    func testAPredictedRemovalThatDoesNotFitIsDropped() {
        let before = bar(primary, [caption(1, "Mail"), caption(2, "Code")])
        XCTAssertNil(MissionControlLabels.predictedLayout(before, centres: [500], removing: 2))
    }

    // MARK: - The current desktop's pill

    /// The Dock selects the third thumbnail; drawn as the first is removed, its label is renumbered second.
    func testTheCurrentDesktopIsToldBySpaceNotPlace() {
        let measured = dockBar(["Desktop 1", "Desktop 2", "Desktop 3"], spaceIDs: ["1", "2", "3"])
        var third = caption(3, "Notes")
        third.index = 1
        var second = caption(2, "Code")
        second.index = 0
        let current = { (caption: Caption) in
            MissionControlLabels.isCurrent(caption, selected: 2, on: measured, currentSpaceIDs: ["2"])
        }
        XCTAssertTrue(current(third))
        XCTAssertFalse(current(second))
    }

    func testASelectionWhoseSpaceIsUnknownHasNoPill() {
        let unknown = dockBar(["Desktop 1", "Desktop 2"], spaceIDs: [])
        XCTAssertFalse(MissionControlLabels.isCurrent(caption(1, "Mail"), selected: 0, on: unknown,
                                                      currentSpaceIDs: ["1"]))
    }

    func testWithoutASelectionMacOSsCurrentSpaceHasThePill() {
        let measured = dockBar(["Desktop 1", "Desktop 2"], spaceIDs: ["1", "2"])
        XCTAssertTrue(MissionControlLabels.isCurrent(caption(2, "Code"), selected: nil, on: measured,
                                                     currentSpaceIDs: ["2"]))
        XCTAssertFalse(MissionControlLabels.isCurrent(caption(1, "Mail"), selected: nil, on: measured,
                                                      currentSpaceIDs: ["2"]))
    }

    // MARK: - Growing into thumbnails

    /// Thumbnails grown last time with other spaces in their places: each label goes to its space's
    /// place now, at the grown thumbnails' spacing.
    func testAGrowthPlacesEachLabelAtItsThumbnailsPlaceNow() {
        let titles = ["Desktop 1", "Desktop 2", "Desktop 3"]
        let grown = dockBar(titles, spaceIDs: ["12", "13", "11"], spacing: 300)
        let now = dockBar(titles, spaceIDs: ["13", "11", "12"], labelsUnnamed: true)
        let placed = grown.placing(now)
        XCTAssertEqual(placed.spaceIDs, now.spaceIDs)
        XCTAssertEqual(placed.captions.map(\.spaceID), ["13", "11", "12"])
        XCTAssertEqual(placed.captions.map(\.name), ["Desktop 1", "Mail", "Desktop 3"])
        XCTAssertEqual(placed.captions.map(\.centre), grown.buttons.map {
            MissionControlLabels.captionCentre(below: $0.frame)
        })
        XCTAssertEqual(placed.captions.map(\.maxWidth), [300, 300, 300].map { $0 - MissionControlLabels.labelGap })
    }

    // MARK: - Magnification

    /// An expanded bar of `count` thumbnails as the Dock reports 16 desktops on a 2560-point screen: 127pt
    /// wide at a 152pt pitch, those in `widths` resized about their middles, each labelled.
    private func thumbnailBar(
        count: Int = 16, height: CGFloat = 146, widths: [Int: CGFloat] = [:], on screen: CGRect? = nil
    ) -> BarLayout {
        let screen = screen ?? primary
        let element = AXUIElementCreateApplication(getpid())
        let buttons = (0..<count).map { index -> (element: AXUIElement, title: String, frame: CGRect) in
            let width = widths[index] ?? 127
            let midX = screen.minX + 100 + CGFloat(index) * 152
            let thumbnailHeight: CGFloat = height > MissionControlLabels.expandedBarHeight ? 77 : 24
            return (element, "Desktop \(index + 1)",
                    CGRect(x: midX - width / 2, y: screen.minY + 8, width: width, height: thumbnailHeight))
        }
        let captions = buttons.indices.map { index in
            Caption(centre: MissionControlLabels.captionCentre(below: buttons[index].frame), maxWidth: 148,
                    index: index, covers: buttons[index].title, name: "Space \(index + 1)", colorHex: nil,
                    spaceID: "\(index + 1)")
        }
        return BarLayout(
            bar: nil, firstButton: nil, frame: CGRect(x: screen.minX, y: screen.minY, width: screen.width,
                                                      height: height),
            firstButtonX: nil, screen: screen, displayID: screen == primary ? 1 : 2, captions: captions,
            buttons: buttons, spaceIDs: captions.map(\.spaceID))
    }

    /// The sixth thumbnail hovered and grown, its neighbours shrunk, as measured.
    private let magnifiedWidths: [Int: CGFloat] = [4: 104, 5: 164, 6: 104]
    private var magnifiedBar: BarLayout { thumbnailBar(widths: magnifiedWidths) }
    private func middle(of place: Int, on bar: BarLayout) -> CGFloat { bar.buttons[place].frame.midX }

    func testThumbnailsOfOneWidthDoNotMagnify() {
        XCTAssertFalse(BarMagnification.showsMagnification(thumbnailBar()))
        let withinTolerance = thumbnailBar(widths: [5: 127 + BarMagnification.widthTolerance])
        XCTAssertFalse(BarMagnification.showsMagnification(withinTolerance))
    }

    func testThumbnailsDifferingInWidthBeyondTheToleranceMagnify() {
        XCTAssertTrue(BarMagnification.showsMagnification(magnifiedBar))
        let justBeyond = thumbnailBar(widths: [5: 127 + BarMagnification.widthTolerance + 0.5])
        XCTAssertTrue(BarMagnification.showsMagnification(justBeyond))
    }

    func testABarOfNamesNeverMagnifies() {
        XCTAssertFalse(BarMagnification.showsMagnification(thumbnailBar(height: 40, widths: magnifiedWidths)))
    }

    /// Over the sixth thumbnail, the one `magnifiedBar` has grown.
    private var overSixth: CGPoint { CGPoint(x: middle(of: 5, on: magnifiedBar), y: 60) }

    /// Learning that magnifies from `magnifiedBar`, hovered, at time 10.
    private func learnedToMagnify() -> BarMagnification {
        var magnification = BarMagnification()
        _ = magnification.learn(from: magnifiedBar, read: 10, pointer: overSixth, at: 10)
        return magnification
    }

    /// A later session's bar, with no thumbnail yet magnified, is known to magnify from its first report.
    func testABarFoundToMagnifyIsRememberedByScreenAndCount() {
        var magnification = BarMagnification()
        XCTAssertNil(magnification.learn(from: thumbnailBar(), read: 10, pointer: overSixth, at: 10))
        XCTAssertFalse(magnification.magnifies(thumbnailBar()))
        XCTAssertEqual(magnification.learn(from: magnifiedBar, read: 10.02, pointer: overSixth, at: 10.02), .magnifies)
        XCTAssertNil(magnification.learn(from: magnifiedBar, read: 10.04, pointer: overSixth, at: 10.04))
        XCTAssertTrue(magnification.magnifies(thumbnailBar()))
        XCTAssertFalse(magnification.magnifies(thumbnailBar(count: 15)))
        XCTAssertFalse(magnification.magnifies(thumbnailBar(count: 11, on: builtIn)))
    }

    /// A thumbnail grown for some other reason, such as a window dragged onto it, tells nothing with the
    /// pointer off the bar.
    func testWidthsTellNothingWithThePointerOffTheBar() {
        var magnification = BarMagnification()
        let below = CGPoint(x: overSixth.x, y: 400)
        XCTAssertNil(magnification.learn(from: magnifiedBar, read: 10, pointer: below, at: 10))
        XCTAssertNil(magnification.learn(from: magnifiedBar, read: 10, pointer: nil, at: 10))
        XCTAssertFalse(magnification.magnifies(magnifiedBar))
    }

    /// The bar's top margin and caption row may not magnify: only the pointer on a thumbnail itself tells.
    func testEvenWidthsTellNothingWithThePointerOffTheThumbnailsThemselves() {
        var magnification = BarMagnification()
        let even = thumbnailBar()
        let thumbnail = even.buttons[5].frame
        for pointer in [CGPoint(x: thumbnail.midX, y: thumbnail.maxY + 5), CGPoint(x: thumbnail.midX, y: 2)] {
            XCTAssertNil(magnification.learn(from: even, read: 10, pointer: pointer, at: 10))
            XCTAssertNil(magnification.learn(from: even, read: 11, pointer: pointer, at: 11))
        }
        XCTAssertTrue(magnification.follows(even))
    }

    /// A Dock slow to answer leaves a reading from before the pointer came onto the thumbnail: only a
    /// reading taken long enough after tells.
    func testEvenWidthsCountOnlyInReadingsTakenAfterThePointerArrived() {
        var magnification = BarMagnification()
        let even = thumbnailBar()
        XCTAssertNil(magnification.learn(from: even, read: 9.9, pointer: overSixth, at: 10))
        XCTAssertNil(magnification.learn(from: even, read: 9.9, pointer: overSixth, at: 10.5))
        XCTAssertNil(magnification.learn(from: even, read: 10.25, pointer: overSixth, at: 10.6))
        XCTAssertEqual(magnification.learn(from: even, read: 10.3, pointer: overSixth, at: 10.62), .doesNotMagnify)
    }

    /// Measured still landing, the bar never matches its measurement once at rest: measured again then, but
    /// not while it moves.
    func testABarAtRestOffWhereItWasMeasuredIsMeasuredAgain() {
        let bar = thumbnailBar()
        let landed = bar.frame.offsetBy(dx: 0, dy: 3)
        XCTAssertTrue(bar.restsOffItsPlace(now: landed, before: landed.offsetBy(dx: 0, dy: 0.3)))
        XCTAssertFalse(bar.restsOffItsPlace(now: landed, before: landed.offsetBy(dx: 0, dy: -4)))
        XCTAssertFalse(bar.restsOffItsPlace(now: landed, before: nil))
        XCTAssertFalse(bar.restsOffItsPlace(now: bar.frame, before: bar.frame))
    }

    func testThumbnailsOfOneWidthUnderThePointerForAWhileDoNotMagnify() {
        var magnification = BarMagnification()
        let even = thumbnailBar()
        let settled = 10 + BarMagnification.evenWidthsTime
        XCTAssertNil(magnification.learn(from: even, read: 10, pointer: overSixth, at: 10))
        let justShort = settled - 0.01
        XCTAssertNil(magnification.learn(from: even, read: justShort, pointer: overSixth, at: justShort))
        XCTAssertEqual(magnification.learn(from: even, read: settled, pointer: overSixth, at: settled),
                       .doesNotMagnify)
        XCTAssertFalse(magnification.magnifies(even))
        XCTAssertFalse(magnification.follows(even))
    }

    /// A run of even widths counts only unbroken, with the pointer over a thumbnail and nothing else moving
    /// them.
    func testARunOfEvenWidthsStartsAgainWhenBroken() {
        var magnification = BarMagnification()
        let even = thumbnailBar()
        let frames = even.buttons.map(\.frame)
        let inGap = CGPoint(x: (frames[5].maxX + frames[6].minX) / 2, y: 60)
        _ = magnification.learn(from: even, read: 10, pointer: overSixth, at: 10)
        XCTAssertNil(magnification.learn(from: even, read: 10.2, pointer: inGap, at: 10.2))
        XCTAssertNil(magnification.learn(from: even, read: 10.35, pointer: overSixth, at: 10.35))
        magnification.interrupt()
        XCTAssertNil(magnification.learn(from: even, read: 10.6, pointer: overSixth, at: 10.6))
        XCTAssertNil(magnification.learn(from: even, read: 10.8, pointer: overSixth, at: 10.8))
        XCTAssertEqual(magnification.learn(from: even, read: 10.9, pointer: overSixth, at: 10.9), .doesNotMagnify)
    }

    func testEvenWidthsUndoAWrongGuessThatABarMagnifies() {
        var magnification = learnedToMagnify()
        let even = thumbnailBar()
        _ = magnification.learn(from: even, read: 11, pointer: overSixth, at: 11)
        XCTAssertEqual(magnification.learn(from: even, read: 11.3, pointer: overSixth, at: 11.3), .doesNotMagnify)
        XCTAssertFalse(magnification.magnifies(magnifiedBar))
    }

    /// Thumbnails not yet known are followed one by one, so one reading tells; those known not to magnify,
    /// and bars of names, never are.
    func testOnlyThumbnailsThatMagnifyOrAreNotYetKnownAreFollowed() {
        var magnification = BarMagnification()
        XCTAssertTrue(magnification.follows(thumbnailBar()))
        XCTAssertFalse(magnification.follows(thumbnailBar(height: 40)))
        _ = magnification.learn(from: magnifiedBar, read: 10, pointer: overSixth, at: 10)
        XCTAssertTrue(magnification.follows(thumbnailBar()))
        let fifteen = thumbnailBar(count: 15)
        _ = magnification.learn(from: fifteen, read: 10, pointer: overSixth, at: 10)
        _ = magnification.learn(from: fifteen, read: 10.3, pointer: overSixth, at: 10.3)
        XCTAssertFalse(magnification.follows(fifteen))
    }

    func testFifteenDesktopsShowEveryLabelWhereverThePointerIs() {
        var magnification = learnedToMagnify()
        let fifteen = thumbnailBar(count: 15)
        XCTAssertNil(magnification.learn(from: fifteen, read: 10, pointer: overSixth, at: 10))
        for pointer in [CGPoint(x: middle(of: 5, on: fifteen), y: 60), CGPoint(x: 5, y: 60), CGPoint(x: 900, y: 700)] {
            let shown = ShownLabels.on(fifteen, magnifies: magnification.magnifies(fifteen), pointer: pointer)
            XCTAssertEqual(shown, .all)
            XCTAssertEqual(fifteen.captions.filter(shown.shows).count, 15)
        }
    }

    func testABarOfNamesShowsEveryLabelThoughItsThumbnailsMagnify() {
        let magnification = learnedToMagnify()
        let names = thumbnailBar(height: 40)
        XCTAssertFalse(magnification.magnifies(names))
        XCTAssertEqual(ShownLabels.on(names, magnifies: magnification.magnifies(names),
                                      pointer: CGPoint(x: 400, y: 20)), .all)
    }

    /// The sixth thumbnail hovered, re-read as it grows and its neighbours shrink.
    func testReReadThumbnailsMoveTheirCaptionsUnderThemAtTheWidthsLeft() throws {
        let bar = thumbnailBar()
        let frames = magnifiedBar.buttons.map(\.frame)
        let followed = try XCTUnwrap(bar.following(count: 16, frames: frames))
        XCTAssertEqual(followed.buttons.map(\.frame), frames)
        XCTAssertEqual(followed.captions.map(\.centre), frames.map(MissionControlLabels.captionCentre(below:)))
        XCTAssertEqual(followed.captions.map(\.spaceID), bar.captions.map(\.spaceID))
        let centres = frames.map(\.midX)
        XCTAssertEqual(followed.captions[5].maxWidth, min(centres[5] - centres[4], centres[6] - centres[5])
                       - MissionControlLabels.labelGap)
        XCTAssertEqual(followed.captions[0].maxWidth, centres[1] - centres[0] - MissionControlLabels.labelGap)
    }

    /// Only the labelled thumbnails have captions: each keeps its own thumbnail's place.
    func testReReadThumbnailsMoveOnlyTheCaptionsThereAre() throws {
        var bar = thumbnailBar()
        bar.captions = [bar.captions[2], bar.captions[9]]
        let frames = magnifiedBar.buttons.map(\.frame)
        let followed = try XCTUnwrap(bar.following(count: 16, frames: frames))
        XCTAssertEqual(followed.captions.map(\.centre),
                       [frames[2], frames[9]].map(MissionControlLabels.captionCentre(below:)))
    }

    func testThumbnailsThatCannotBeReReadOrChangedInNumberAreMeasuredAgain() {
        let bar = thumbnailBar()
        let frames = magnifiedBar.buttons.map(\.frame)
        XCTAssertNil(bar.following(count: 16, frames: nil))
        XCTAssertNil(bar.following(count: nil, frames: frames))
        XCTAssertNil(bar.following(count: 17, frames: frames))
        XCTAssertNil(bar.following(count: 16, frames: Array(frames.dropLast())))
    }

    /// So the reader's test for the strip sliding compares with the thumbnails as last read.
    func testReReadThumbnailsMoveTheFirstAndLastMarkers() throws {
        let frames = magnifiedBar.buttons.map(\.frame)
        let followed = try XCTUnwrap(thumbnailBar().following(count: 16, frames: frames))
        XCTAssertEqual(followed.firstButtonX, frames[0].minX)
        XCTAssertEqual(followed.lastButtonX, frames[15].minX)
    }

    /// Sliding in or out, the bar carries its thumbnails: they are followed only with the bar where it was
    /// measured, or the labels would move twice.
    func testThumbnailsAreFollowedOnlyWithTheBarWhereItWasMeasured() {
        let bar = thumbnailBar()
        XCTAssertTrue(bar.isWhereMeasured(now: bar.frame))
        XCTAssertTrue(bar.isWhereMeasured(now: bar.frame.offsetBy(dx: 0.4, dy: -0.4)))
        XCTAssertFalse(bar.isWhereMeasured(now: bar.frame.offsetBy(dx: 0, dy: -20)))
        XCTAssertFalse(bar.isWhereMeasured(now: bar.frame.insetBy(dx: 0, dy: 10)))
    }

    func testThumbnailsSlidingTogetherAtTheirWidthsAreAShift() {
        let before = magnifiedBar
        XCTAssertEqual(before.offsetBy(dx: 76).thumbnailShift(since: before), 76)
        XCTAssertNil(magnifiedBar.thumbnailShift(since: thumbnailBar()))
        var oneResized = thumbnailBar().offsetBy(dx: 76)
        oneResized.buttons[0].frame = oneResized.buttons[0].frame.insetBy(dx: 10, dy: 0)
        XCTAssertNil(oneResized.thumbnailShift(since: thumbnailBar()))
    }

    /// With one labelled space, its caption moving as its thumbnail grows looked like the whole strip sliding.
    func testOnAResizingBarALoneCaptionMovingIsNoShift() throws {
        var before = thumbnailBar()
        before.captions = [before.captions[5]]
        // The sixth grows 30pt to the right, pushing the rest along.
        let frames = before.buttons.map(\.frame).enumerated().map { index, frame in
            index == 5 ? CGRect(x: frame.minX, y: frame.minY, width: frame.width + 30, height: frame.height)
                : index > 5 ? frame.offsetBy(dx: 30, dy: 0) : frame
        }
        let after = try XCTUnwrap(before.following(count: 16, frames: frames))
        XCTAssertEqual(MissionControlLabels.sidewaysShift(from: before, to: after, byThumbnails: false), 15)
        XCTAssertNil(MissionControlLabels.sidewaysShift(from: before, to: after, byThumbnails: true))
        let slid = before.offsetBy(dx: -40)
        XCTAssertEqual(MissionControlLabels.sidewaysShift(from: before, to: slid, byThumbnails: true), -40)
    }

    func testThumbnailsMovingOverHalfAPointCountAsMotion() {
        let bar = thumbnailBar()
        XCTAssertFalse(bar.thumbnailsMoved(since: bar))
        XCTAssertFalse(bar.offsetBy(dx: 0.4).thumbnailsMoved(since: bar))
        XCTAssertTrue(bar.offsetBy(dx: 0.6).thumbnailsMoved(since: bar))
        XCTAssertTrue(magnifiedBar.thumbnailsMoved(since: bar))
        XCTAssertTrue(thumbnailBar(count: 15).thumbnailsMoved(since: bar))
    }

    func testAMagnifyingBarsReadingLogsEachThumbnailsLeftEdgeAndWidth() {
        let bar = thumbnailBar(count: 2, widths: [1: 163])
        XCTAssertEqual(MissionControlLabels.thumbnailFrames(of: bar), "display 1 thumbnails 36.5,127.0 170.5,163.0")
    }

    func testOnlyTheHoveredThumbnailsLabelShows() {
        let pointer = CGPoint(x: middle(of: 5, on: magnifiedBar), y: 60)
        let shown = ShownLabels.on(magnifiedBar, magnifies: true, pointer: pointer)
        XCTAssertEqual(shown, .only(5))
        XCTAssertEqual(magnifiedBar.captions.filter(shown.shows).map(\.spaceID), ["6"])
    }

    func testTheHoveredThumbnailChangesExactlyAtTheMiddleOfTheGap() {
        let frames = magnifiedBar.buttons.map(\.frame)
        let gapMiddle = (frames[5].maxX + frames[6].minX) / 2
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: gapMiddle - 0.5), 5)
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: gapMiddle), 6)
        let before = (frames[4].maxX + frames[5].minX) / 2
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: before), 5)
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: before - 0.5), 4)
    }

    /// The strip slides in from the screen's edge, leaving the pointer beyond its end thumbnail: macOS
    /// draws no caption more than half the bar's 25pt gap past it.
    func testPastEitherEndOfTheStripNoThumbnailIsHovered() {
        let frames = magnifiedBar.buttons.map(\.frame)
        XCTAssertNil(ShownLabels.hoveredThumbnail(frames, at: frames[0].minX - 12.5 - 0.5))
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: frames[0].minX - 12.5), 0)
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: frames[15].maxX + 12.5 - 0.5), 15)
        XCTAssertNil(ShownLabels.hoveredThumbnail(frames, at: frames[15].maxX + 12.5))
        XCTAssertEqual(ShownLabels.on(magnifiedBar, magnifies: true, pointer: CGPoint(x: 10, y: 60)), .none)
    }

    /// 16 thumbnails 127pt wide, 24pt apart, the first at x 73.
    private var barGappedBy24: BarLayout {
        var bar = thumbnailBar()
        for index in bar.buttons.indices {
            bar.buttons[index].frame.origin.x = 73 + CGFloat(index) * (127 + 24)
        }
        return bar
    }

    /// Recorded: the pointer resting at x 70, left of the first thumbnail's edge at 73, had macOS caption it.
    func testTheFirstThumbnailsSpanReachesHalfTheGapPastItsLeftEdge() {
        let bar = barGappedBy24
        let frames = bar.buttons.map(\.frame)
        XCTAssertEqual(ShownLabels.on(bar, magnifies: true, pointer: CGPoint(x: 70, y: 60)), .only(0))
        XCTAssertEqual(ShownLabels.on(bar, magnifies: true, pointer: CGPoint(x: 40, y: 60)), .none)
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: 61), 0)
        XCTAssertNil(ShownLabels.hoveredThumbnail(frames, at: 60.5))
    }

    func testTheLastThumbnailsSpanReachesHalfTheGapPastItsRightEdge() {
        let bar = barGappedBy24
        let edge = bar.buttons[15].frame.maxX
        XCTAssertEqual(ShownLabels.on(bar, magnifies: true, pointer: CGPoint(x: edge + 3, y: 60)), .only(15))
        XCTAssertEqual(ShownLabels.on(bar, magnifies: true, pointer: CGPoint(x: edge + 33, y: 60)), .none)
        let frames = bar.buttons.map(\.frame)
        XCTAssertEqual(ShownLabels.hoveredThumbnail(frames, at: edge + 11.5), 15)
        XCTAssertNil(ShownLabels.hoveredThumbnail(frames, at: edge + 12))
    }

    func testALoneThumbnailsSpanStopsAtItsEdges() {
        let frame = CGRect(x: 73, y: 8, width: 127, height: 77)
        XCTAssertEqual(ShownLabels.hoveredThumbnail([frame], at: 73), 0)
        XCTAssertNil(ShownLabels.hoveredThumbnail([frame], at: 72.5))
        XCTAssertNil(ShownLabels.hoveredThumbnail([frame], at: 200))
    }

    private let frameDuration: TimeInterval = 1.0 / 60
    private var gapMiddleAfterSixth: CGFloat {
        let frames = magnifiedBar.buttons.map(\.frame)
        return (frames[5].maxX + frames[6].minX) / 2
    }

    private func shown(at x: CGFloat, speed: CGFloat, keeping kept: Int? = nil) -> ShownLabels {
        ShownLabels.on(magnifiedBar, magnifies: true, pointer: CGPoint(x: x, y: 60),
                       reach: ShownLabels.reach(speed: speed, frameDuration: frameDuration), keeping: kept)
    }

    /// At 1200pt a second the pointer covers 40pt in two frames: within that of a gap's middle, macOS may caption
    /// either thumbnail by the time the labels reach the screen.
    func testAFastPointerNearAGapsMiddleShowsBothThumbnailsLabels() {
        let gap = gapMiddleAfterSixth
        XCTAssertEqual(shown(at: gap - 10, speed: 1200), .only(5, also: [6]))
        XCTAssertEqual(shown(at: gap + 10, speed: 1200), .only(6, also: [5]))
        XCTAssertEqual(magnifiedBar.captions.filter(shown(at: gap - 10, speed: 1200).shows).map(\.spaceID),
                       ["6", "7"])
        XCTAssertEqual(shown(at: gap - 40.5, speed: 1200), .only(5))
        XCTAssertEqual(shown(at: middle(of: 5, on: magnifiedBar), speed: 1200), .only(5))
    }

    func testAStillPointerShowsOnlyTheHoveredLabelHoweverNearTheGap() {
        XCTAssertEqual(shown(at: gapMiddleAfterSixth - 0.5, speed: 0), .only(5))
        XCTAssertEqual(shown(at: gapMiddleAfterSixth, speed: 0), .only(6))
    }

    func testTheReachScalesWithSpeedAndIsAtLeastThreePoints() {
        XCTAssertEqual(ShownLabels.reach(speed: 0, frameDuration: frameDuration), 0)
        XCTAssertEqual(ShownLabels.reach(speed: 30, frameDuration: frameDuration), 3)
        XCTAssertEqual(ShownLabels.reach(speed: 600, frameDuration: frameDuration), 20, accuracy: 0.001)
        XCTAssertEqual(ShownLabels.reach(speed: 1200, frameDuration: frameDuration), 40, accuracy: 0.001)
        XCTAssertEqual(ShownLabels.reach(speed: 600, frameDuration: 1.0 / 120), 10, accuracy: 0.001)
        let gap = gapMiddleAfterSixth
        XCTAssertEqual(shown(at: gap - 2.5, speed: 30), .only(5, also: [6]))
        XCTAssertEqual(shown(at: gap - 3, speed: 30), .only(5))
        XCTAssertEqual(shown(at: gap - 19.5, speed: 600), .only(5, also: [6]))
        XCTAssertEqual(shown(at: gap - 20.5, speed: 600), .only(5))
    }

    /// A pointer so fast its reach spans a whole thumbnail covers the gaps either side of it.
    func testAReachOverBothGapsShowsTheThumbnailsBesideEach() {
        XCTAssertEqual(shown(at: middle(of: 5, on: magnifiedBar), speed: 3000), .only(5, also: [4, 6]))
    }

    /// The hover moving from the sixth thumbnail to the seventh, then the pointer far past the gap: the sixth's label
    /// stays in the frame of the crossing and the two after, then goes.
    func testTheLabelTheHoverLeftIsKeptForExactlyTwoFramesAfterTheCrossing() {
        var trail = HoverTrail()
        trail.note(5, at: 0)
        XCTAssertNil(trail.kept(at: 0, frameDuration: frameDuration))
        trail.note(6, at: frameDuration)
        let farPast = middle(of: 6, on: magnifiedBar)
        let shownByFrame = (1...5).map { frame in
            shown(at: farPast, speed: 0,
                  keeping: trail.kept(at: Double(frame) * frameDuration, frameDuration: frameDuration))
        }
        XCTAssertEqual(shownByFrame, [.only(6, also: [5]), .only(6, also: [5]), .only(6, also: [5]), .only(6),
                                      .only(6)])
    }

    func testTheHoverLeavingTheThumbnailsKeepsNoLabel() {
        var trail = HoverTrail()
        trail.note(5, at: 0)
        trail.note(nil, at: frameDuration)
        XCTAssertNil(trail.kept(at: frameDuration, frameDuration: frameDuration))
        trail.note(nil, at: 2 * frameDuration)
        trail.note(6, at: 3 * frameDuration)
        XCTAssertNil(trail.kept(at: 3 * frameDuration, frameDuration: frameDuration))
    }

    func testThePointersSpeedComesFromItsLastFewFramesAndFallsToNoneAtRest() {
        var pace = PointerPace()
        XCTAssertEqual(pace.speed, 0)
        for (frame, x) in [100, 110, 120].enumerated() {
            pace.note(CGPoint(x: CGFloat(x), y: 60), at: Double(frame) * frameDuration)
        }
        XCTAssertEqual(pace.speed, 600, accuracy: 0.001)
        for frame in 3...6 { pace.note(CGPoint(x: 120, y: 60), at: Double(frame) * frameDuration) }
        XCTAssertEqual(pace.speed, 0)
        pace.note(CGPoint(x: 200, y: 60), at: 7 * frameDuration)
        pace.note(nil, at: 8 * frameDuration)
        XCTAssertEqual(pace.speed, 0)
    }

    func testTheRecordingListsEveryLabelShown() {
        let bar = magnifiedBar
        XCTAssertEqual(MissionControlLabels.shownRecord(bar: bar, shown: .only(9, also: [8])), "display 1 hovered 9+10")
        XCTAssertEqual(MissionControlLabels.shownRecord(bar: bar, shown: .only(4)), "display 1 hovered 5")
        XCTAssertEqual(MissionControlLabels.shownRecord(bar: bar, shown: .all), "display 1 all")
        XCTAssertEqual(MissionControlLabels.shownRecord(bar: bar, shown: .none), "display 1 none")
    }

    func testWithThePointerOffAMagnifyingBarNoLabelShows() {
        let x = middle(of: 5, on: magnifiedBar)
        XCTAssertEqual(ShownLabels.on(magnifiedBar, magnifies: true, pointer: CGPoint(x: x, y: 146)), .only(5))
        XCTAssertEqual(ShownLabels.on(magnifiedBar, magnifies: true, pointer: CGPoint(x: x, y: 146.5)), .none)
        XCTAssertEqual(ShownLabels.on(magnifiedBar, magnifies: true, pointer: nil), .none)
        XCTAssertTrue(magnifiedBar.captions.filter(ShownLabels.none.shows).isEmpty)
    }


    // MARK: - Caption strips

    private let rowLeft = (20, 30, 90)
    private let rowRight = (80, 60, 170)

    /// The bar's colour `x` points across the 400pt row, blending from `rowLeft` to `rowRight`.
    private func rowColor(at x: CGFloat) -> (Int, Int, Int) {
        func mix(_ left: Int, _ right: Int) -> Int { Int((CGFloat(left) + CGFloat(right - left) * x / 400).rounded()) }
        return (mix(rowLeft.0, rowRight.0), mix(rowLeft.1, rowRight.1), mix(rowLeft.2, rowRight.2))
    }

    private func textAttributes(alpha: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14),
         NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(textColor).copy(alpha: alpha) ?? 0]
    }

    /// A 2x capture of a magnifying bar's caption row, 400x60pt: bar blending across the screen and, unless
    /// `caption` is false, "Desktop 9" on a baseline 50pt down, its ink centred at x = 300 or its advance at
    /// `advanceCentre`; in the pill when `inPill`, reaching `pillRight` beyond the text on the right. With `ghostAt`,
    /// "Desktop 8" fading out there.
    private func magnifyingRow(
        caption: Bool = true, inPill: Bool = false, pillRight: CGFloat = 11.5, advanceCentre: CGFloat? = nil,
        ghostAt: CGFloat? = nil
    ) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 120, bitsPerComponent: 8, bytesPerRow: 800 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        for x in 0..<800 {
            context.setFillColor(cgColor(rowColor(at: (CGFloat(x) + 0.5) / 2)))
            context.fill(CGRect(x: CGFloat(x) / 2, y: 0, width: 0.5, height: 60))
        }
        let baseline: CGFloat = 10  // 50pt down from the top, measured from the bottom
        if let ghostAt {
            let ghost = CTLineCreateWithAttributedString(
                NSAttributedString(string: "Desktop 8", attributes: textAttributes(alpha: 0.7)))
            context.textPosition = CGPoint(x: ghostAt - CTLineGetBoundsWithOptions(ghost, .useGlyphPathBounds).midX,
                                           y: baseline)
            CTLineDraw(ghost, context)
        }
        guard caption else { return try XCTUnwrap(context.makeImage()) }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Desktop 9", attributes: textAttributes()))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let left = advanceCentre.map { $0 - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / 2 }
            ?? 300 - ink.midX
        if inPill {
            let pill = CGRect(x: left + ink.minX - 11.5, y: baseline - 7, width: ink.width + 11.5 + pillRight,
                              height: 24)
            context.setFillColor(cgColor(pillColor))
            context.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
        }
        context.textPosition = CGPoint(x: left, y: baseline)
        CTLineDraw(line, context)
        return try XCTUnwrap(context.makeImage())
    }

    /// The Dock puts the hovered caption's centre 45pt down, under the middle of its thumbnail at x = 300, two
    /// thumbnails `maxWidth` wide; its text sits on a baseline 50pt down. The bar's top is at `barTop`.
    private func hoveredInRow(barTop: CGFloat = 0, maxWidth: CGFloat = 260) -> CaptionToMatch {
        CaptionToMatch(key: "row", centre: CGPoint(x: 300, y: 45), barTop: barTop, barBottom: 58, maxWidth: maxWidth,
                       covers: "Desktop 9", name: "")
    }

    private func capturedRow(
        _ image: CGImage, hovered: CaptionToMatch? = nil
    ) -> MissionControlCaptionLook.StripCapture {
        MissionControlCaptionLook.strip(in: image, origin: .zero, scale: 2, hovered: hovered ?? hoveredInRow(),
                                        background: "hills")
    }

    private func stripOfRow(_ image: CGImage, hovered: CaptionToMatch? = nil) throws -> CaptionStrip {
        let captured = capturedRow(image, hovered: hovered)
        if case .strip(let strip, _) = captured { return strip }
        return try XCTUnwrap(nil as CaptionStrip?, "no strip: \(captured)")
    }

    private func missOfRow(_ image: CGImage, hovered: CaptionToMatch? = nil) -> String? {
        if case .missed(let reason, _) = capturedRow(image, hovered: hovered) { return reason }
        return nil
    }

    private func components(_ color: CGColor) throws -> (Int, Int, Int) {
        let srgb = try XCTUnwrap(color.converted(
            to: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), intent: .defaultIntent, options: nil))
        let parts = try XCTUnwrap(srgb.components)
        return (Int((parts[0] * 255).rounded()), Int((parts[1] * 255).rounded()), Int((parts[2] * 255).rounded()))
    }

    func testAStripIsTheCaptionRowAcrossTheScreenWithItsOneCaptionErased() throws {
        let row = try magnifyingRow()
        let strip = try stripOfRow(row)
        // 18pt above the baseline and 8pt below, across the whole capture, its top below the screen's.
        XCTAssertEqual(strip.image.width, 800)
        XCTAssertEqual(strip.top, 32, accuracy: 0.01)
        XCTAssertEqual(strip.height, 26, accuracy: 0.01)
        XCTAssertEqual(strip.baseline, 18, accuracy: 0.01)
        let pixels = try pixels(strip.image)
        // Through the native text, 4pt above the baseline: bar, as it blends there.
        for x in stride(from: 262, through: 338, by: 4) {
            assertColor(pixels[28][x * 2], rowColor(at: CGFloat(x) + 0.25))
        }
        // Away from the caption the strip is the capture itself.
        let captured = try self.pixels(row)
        for x in [0, 300, 799] {
            XCTAssertTrue(pixels[0][x] == captured[64][x] && pixels[51][x] == captured[115][x])
        }
    }

    func testAStripMeasuresItsCaptionsText() throws {
        let strip = try stripOfRow(try magnifyingRow())
        XCTAssertEqual(strip.text.fontSize, 14, accuracy: 0.25)
        assertColor(try components(strip.text.color), textColor)
        XCTAssertNil(strip.pill)
    }

    func testAStripOfTheCurrentSpacesCaptionMeasuresAndErasesItsPill() throws {
        let strip = try stripOfRow(try magnifyingRow(inPill: true))
        let pill = try XCTUnwrap(strip.pill)
        assertColor(try components(pill.color), pillColor)
        XCTAssertEqual(pill.padding, 11.5, accuracy: 0.5)
        XCTAssertEqual(pill.above, 17, accuracy: 0.5)
        XCTAssertEqual(pill.below, 7, accuracy: 0.5)
        // Where the pill was, left of the text: bar.
        assertColor(try pixels(strip.image)[strip.image.height / 2][520], rowColor(at: 260.25))
    }

    /// Side bearings can sit the text off the pill's middle: the pill is drawn as wide as its wider side either side.
    func testAPillsPaddingIsItsWiderSide() throws {
        let strip = try stripOfRow(try magnifyingRow(inPill: true, pillRight: 13.5))
        XCTAssertEqual(try XCTUnwrap(strip.pill).padding, 13.5, accuracy: 0.5)
    }

    func testARowWithNoCaptionGivesNoStrip() throws {
        XCTAssertNotNil(missOfRow(try magnifyingRow(caption: false)))
    }

    /// A neighbour's caption caught fading out would be baked into the strip.
    func testTextLeftBesideTheCaptionRejectsTheStrip() throws {
        XCTAssertEqual(missOfRow(try magnifyingRow(ghostAt: 120)), "text left beside the caption")
    }

    /// Further off than a neighbour's caption can be, text is a steady feature of the row: it would reject every strip.
    func testTextIsLookedForOnlyTwoThumbnailsWidthsEitherSideOfTheCaption() throws {
        let narrow = hoveredInRow(maxWidth: 100)
        XCTAssertEqual(missOfRow(try magnifyingRow(ghostAt: 200), hovered: narrow), "text left beside the caption")
        XCTAssertNotNil(try stripOfRow(try magnifyingRow(ghostAt: 120), hovered: narrow))
    }

    /// A capture rejected for what was left beside the caption still saw the bar beside it, and where the caption sat.
    func testACaptureRejectedForTextBesideTheCaptionStillSeesTheBarAndTheCaption() throws {
        guard case .missed(_, let seen) = capturedRow(try magnifyingRow(advanceCentre: 300, ghostAt: 120)), let seen
        else { return XCTFail("nothing seen") }
        assertColor(try components(try XCTUnwrap(seen.barColor)), rowColor(at: 300))
        assertColor(try components(seen.textColor), textColor)
        XCTAssertEqual(seen.baseline, 50, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(seen.lineOffset), 0, accuracy: 0.5)
    }

    /// The overlay draws the labels with the bar's top lifted by the bar's retraction, so depths measured from the
    /// screen's top would lift a bar resting a little short of fully in twice.
    func testAStripsDepthsAreMeasuredFromTheBarsTopWhereTheOverlayPutsIt() throws {
        XCTAssertEqual(CaptionStrips.depthTop(of: thumbnailBar()), primary.minY)
        let short = bar(primary, height: 146, retraction: 0.03, [caption(3, "Docs")])
        XCTAssertEqual(CaptionStrips.depthTop(of: short), primary.minY - 0.03 * 146, accuracy: 0.001)
        let strip = try stripOfRow(try magnifyingRow(), hovered: hoveredInRow(barTop: -4))
        XCTAssertEqual(strip.top, 36, accuracy: 0.01)
    }

    /// macOS centres the line of text on the thumbnail, by its advance: where its ink falls differs by caption.
    func testAStripMeasuresWhereMacOSCentresTheLineAndPlacesOtherCaptionsBy() throws {
        let strip = try stripOfRow(try magnifyingRow(advanceCentre: 303))
        XCTAssertEqual(strip.lineOffset, 3, accuracy: 0.5)
        let offset = MissionControlCaptionLook.inkOffset(of: "Desktop 12", size: 14)
        XCTAssertEqual(strip.inkCentre(underThumbnailAt: 500, inkOffset: offset), 500 + strip.lineOffset + offset)
    }

    func testACaptionFarOffItsThumbnailsMiddleWasCaughtMovingAndGivesNoStrip() throws {
        XCTAssertEqual(missOfRow(try magnifyingRow(advanceCentre: 312))?.hasSuffix("off its thumbnail's middle"), true)
    }

    func testTheBarsColourIsMeasuredBesideEachCaption() throws {
        let looks = try matchSyntheticBar()
        assertColor(try components(try XCTUnwrap(looks["other"]?.barColor)), barColor)
        assertColor(try components(try XCTUnwrap(looks["current"]?.barColor)), barColor)
    }

    /// A strip 400pt across at 2x, `height` points tall, over `background`, its text in `text`.
    private func strip(
        height: CGFloat = 26, background: String = "hills", pill: Bool = false, text: (Int, Int, Int)? = nil,
        lineOffset: CGFloat = 0.5
    ) throws -> CaptionStrip {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: Int(height * 2), bitsPerComponent: 8, bytesPerRow: 800 * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(cgColor(barColor))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: Int(height * 2)))
        return CaptionStrip(
            image: try XCTUnwrap(context.makeImage()), scale: 2, top: 116, baseline: 18, lineOffset: lineOffset,
            text: CaptionStrip.TextStyle(fontSize: 14, color: cgColor(text ?? textColor)),
            pill: pill ? CaptionStrip.PillStyle(padding: 11.5, above: 17, below: 7, color: cgColor(pillColor)) : nil,
            background: background)
    }

    func testAStripIsCroppedWhereTheLabelIsDrawnOnWholePixels() throws {
        let strip = try strip()
        let placed = strip.placement(centreX: 300.3, width: 80, screenLeft: 0)
        XCTAssertEqual(placed.left, 260.5)
        XCTAssertEqual(placed.crop.minX * 800, 521, accuracy: 0.001)
        XCTAssertEqual(placed.crop.width * 800, 160, accuracy: 0.001)
        XCTAssertEqual(placed.crop.minY, 0)
        XCTAssertEqual(placed.crop.height, 1)
        // The label moves with its thumbnail, and the part of the strip behind it with it.
        let moved = strip.placement(centreX: 310.3, width: 80, screenLeft: 0)
        XCTAssertEqual(moved.crop.minX * 800, 541, accuracy: 0.001)
        // On a screen further right, the same part of its own strip.
        let right = strip.placement(centreX: 2860.3, width: 80, screenLeft: 2560)
        XCTAssertEqual(right.left, 2820.5)
        XCTAssertEqual(right.crop, placed.crop)
    }

    func testAStripLabelHidesTheNativeCaptionAndItsPillAndSitsOnTheBaseline() throws {
        let strip = try strip(pill: true)
        let style = CaptionStrip.Style(text: strip.text, pill: strip.pill)
        let name = try XCTUnwrap(NameImage.render("Mail", style: strip.text, scale: 2))
        let covers = MissionControlCaptionLook.inkBounds(of: "Desktop 9", size: 14).width
        let current = strip.layout(name: name, coversWidth: covers, style: style, current: true)
        let pill = try XCTUnwrap(current.pill)
        // Half a pixel larger all round than the native pill round "Desktop 9", which is wider than "Mail".
        XCTAssertEqual(pill.frame.width, covers + 23 + 0.5, accuracy: 0.01)
        XCTAssertEqual(pill.frame.minY, 18 - 17 - 0.25, accuracy: 0.01)
        XCTAssertEqual(pill.frame.height, 24.5, accuracy: 0.01)
        XCTAssertEqual(pill.frame.midX, current.size.width / 2, accuracy: 0.01)
        // At least 2 pixels beyond the pill either side.
        XCTAssertGreaterThanOrEqual(pill.frame.minX, 1)
        XCTAssertLessThanOrEqual(pill.frame.maxX, current.size.width - 1)
        XCTAssertEqual(current.size.height, 26)
        XCTAssertEqual(current.nameFrame.minX + name.inkMidX, current.size.width / 2, accuracy: 0.25)
        XCTAssertEqual(current.nameFrame.minY + name.baseline, 18, accuracy: 0.25)
        // As wide when not the current space's, so it hides the pill should macOS move it here first.
        let plain = strip.layout(name: name, coversWidth: covers, style: style, current: false)
        XCTAssertNil(plain.pill)
        XCTAssertEqual(plain.size, current.size)
        // Each caption's own native text: a wider one widens the label.
        let wider = MissionControlCaptionLook.inkBounds(of: "Desktop 16", size: 14).width
        XCTAssertGreaterThan(strip.layout(name: name, coversWidth: wider, style: style, current: true).size.width,
                             current.size.width)
        // A name wider than the native caption widens the label to hold it.
        let long = try XCTUnwrap(NameImage.render("A much longer name", style: strip.text, scale: 2))
        let wide = strip.layout(name: long, coversWidth: covers, style: style, current: true)
        XCTAssertEqual(wide.pill?.frame.width ?? 0, long.inkWidth + 23.5, accuracy: 0.01)
    }

    func testANameIsRenderedInItsTextStyle() throws {
        let name = try XCTUnwrap(NameImage.render("Mail", style: .init(fontSize: 14, color: cgColor(textColor)),
                                                  scale: 2))
        XCTAssertEqual(name.inkWidth, MissionControlCaptionLook.inkBounds(of: "Mail", size: 14).width, accuracy: 0.01)
        XCTAssertEqual(CGFloat(name.image.width), name.size.width * 2)
        let brightest = try pixels(name.image).joined().max { $0.0 + $0.1 + $0.2 < $1.0 + $1.1 + $1.2 }
        assertColor(try XCTUnwrap(brightest), textColor)
    }

    // MARK: Strips that agree

    func testStripsAgreeOnTextOfTheSameSizeAndColourCentredAlikeAndPillsOfTheSameColour() throws {
        let strip = try strip(pill: true)
        XCTAssertTrue(strip.agrees(with: try self.strip(text: (241, 242, 250))))
        XCTAssertFalse(strip.agrees(with: try self.strip(text: (200, 200, 210))))
        // Caught as the thumbnails moved, a caption is measured off its centre.
        XCTAssertTrue(strip.agrees(with: try self.strip(lineOffset: 1.5)))
        XCTAssertFalse(strip.agrees(with: try self.strip(lineOffset: 1.6)))
        XCTAssertFalse(strip.agrees(with: try self.strip(lineOffset: -0.6)))
        let otherPill = CaptionStrip(
            image: strip.image, scale: 2, top: 116, baseline: 18, lineOffset: 0.5, text: strip.text,
            pill: .init(padding: 11.5, above: 17, below: 7, color: cgColor((30, 30, 120))), background: "hills")
        XCTAssertFalse(strip.agrees(with: otherPill))
        let bigger = CaptionStrip(
            image: strip.image, scale: 2, top: 116, baseline: 18, lineOffset: 0.5,
            text: .init(fontSize: 15, color: cgColor(textColor)), pill: nil, background: "hills")
        XCTAssertFalse(strip.agrees(with: bigger))
    }

    // MARK: Style before a caption is measured

    private let namesRowText = (230, 230, 240)
    private let namesRowPill = (40, 90, 200)

    func testUntilACaptionIsMeasuredLabelsTakeTheNativeTextInTheColourMeasuredOnTheScreen() throws {
        let style = CaptionStrip.style(
            of: nil, measured: CaptionLooks.Colors(text: cgColor(namesRowText), pill: cgColor(namesRowPill)))
        XCTAssertEqual(style.text.fontSize, 14)
        assertColor(try components(style.text.color), namesRowText)
        let pill = try XCTUnwrap(style.pill)
        assertColor(try components(pill.color), namesRowPill)
        XCTAssertEqual([pill.padding, pill.above, pill.below], [11.5, 17, 7])
    }

    func testWithNothingMeasuredLabelsAreWhiteWithNoPill() throws {
        let style = CaptionStrip.style(of: nil, measured: CaptionLooks.Colors())
        assertColor(try components(style.text.color), (255, 255, 255))
        XCTAssertNil(style.pill)
    }

    func testAStripWithoutAPillTakesTheColourOfOneMeasuredOnTheScreen() throws {
        let strip = try strip()
        let style = CaptionStrip.style(
            of: strip, measured: CaptionLooks.Colors(text: cgColor(namesRowText), pill: cgColor(namesRowPill)))
        XCTAssertEqual(style.text, strip.text)
        assertColor(try components(try XCTUnwrap(style.pill?.color)), namesRowPill)
    }

    func testAStripsOwnPillIsUsedOnceMeasured() throws {
        let strip = try strip(pill: true)
        XCTAssertEqual(CaptionStrip.style(of: strip, measured: CaptionLooks.Colors(pill: cgColor(namesRowPill))).pill,
                       strip.pill)
    }

    func testColoursMeasuredOnAScreenComeFromItsBarAtThatHeightFirstThenTheNamesRow() throws {
        var looks = CaptionLooks()
        let names = mainBar
        let expanded = bar(primary, height: 146, [caption(3, "Docs")])
        func colored(_ text: (Int, Int, Int), pill: (Int, Int, Int)?, bar: (Int, Int, Int)) throws
            -> NativeCaptionLook {
            var made = try look(top: 7.5)
            made.textColor = cgColor(text)
            made.pillColor = pill.map(cgColor)
            made.barColor = cgColor(bar)
            return made
        }
        let namesLooks = [CaptionLooks.keys(bar: names, caption: mail).exact:
                            try colored(namesRowText, pill: namesRowPill, bar: (10, 10, 40))]
        _ = looks.finish(looks.capture(of: [names], attempt: 1), CaptionLooks.Result(found: namesLooks), moved: false)
        var colors = looks.measuredColors(onScreen: primaryKey, height: 146)
        assertColor(try components(try XCTUnwrap(colors.text)), namesRowText)
        assertColor(try components(try XCTUnwrap(colors.pill)), namesRowPill)
        assertColor(try components(try XCTUnwrap(colors.bar)), (10, 10, 40))
        let expandedLooks = [CaptionLooks.keys(bar: expanded, caption: caption(3, "Docs")).exact:
                                try colored(textColor, pill: nil, bar: barColor)]
        _ = looks.finish(looks.capture(of: [expanded], attempt: 1), CaptionLooks.Result(found: expandedLooks),
                         moved: false)
        colors = looks.measuredColors(onScreen: primaryKey, height: 146)
        assertColor(try components(try XCTUnwrap(colors.text)), textColor)
        assertColor(try components(try XCTUnwrap(colors.pill)), namesRowPill)
        assertColor(try components(try XCTUnwrap(colors.bar)), barColor)
        XCTAssertNil(looks.measuredColors(onScreen: builtInKey, height: 146).text)
    }

    // MARK: Strips kept and captured

    private let primaryInfo = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), displayID: 1,
                                         uuid: "PRIMARY", scale: 2)

    /// Strips in a session with the primary screen showing `background`.
    private func strips(background: String = "hills") -> CaptionStrips {
        var strips = CaptionStrips()
        strips.beginSession(backgrounds: [primaryKey: background], screens: [primaryInfo])
        return strips
    }

    private var magnifiedKey: String { CaptionStrip.key(display: "PRIMARY", screen: primary.size, barHeight: 146) }

    /// The magnified bar drawn at `time` with the thumbnail at `place` hovered, measured to have `colors`.
    @discardableResult
    private func drawn(_ strips: inout CaptionStrips, hovered place: Int?, at time: TimeInterval,
                       colors: CaptionLooks.Colors = CaptionLooks.Colors()) -> StripDrawing {
        strips.drawing(for: magnifiedBar, hovered: place, colors: { colors }, at: time)
    }

    /// A capture of the magnified bar's strip with the thumbnail at `place` hovered, and everything steady, since
    /// `since`, at `time`.
    private func capture(_ strips: inout CaptionStrips, hovered place: Int = 5, current: Bool = false,
                         since: TimeInterval = 10, at time: TimeInterval = 10.2) -> CaptionStrips.Capture? {
        drawn(&strips, hovered: place, at: since)
        return due(strips, hovered: place, current: current, at: time, steadySince: since)
    }

    /// The capture due of the magnified bar's strip, with the thumbnail at `place` hovered, at `time`.
    private func due(_ strips: CaptionStrips, hovered place: Int = 5, current: Bool = false, at time: TimeInterval,
                     steadySince: TimeInterval = 9) -> CaptionStrips.Capture? {
        strips.capture(key: magnifiedKey, hovered: place, current: current,
                       thumbnail: magnifiedBar.buttons[place].frame, at: time, steadySince: steadySince)
    }

    /// What a capture saw of the hovered caption: the bar beside it in `bar`, its baseline 133pt below the bar's top,
    /// and its line 1pt right of its thumbnail's middle.
    private func sighting(bar: (Int, Int, Int)?) -> CaptionSighting {
        CaptionSighting(barColor: bar.map(cgColor), textColor: cgColor(textColor), baseline: 133, lineOffset: 1)
    }

    func testAStripIsKeptByDisplayScreenSizeAndBarHeightWhateverTheNumberOfThumbnails() {
        XCTAssertEqual(CaptionStrip.key(display: "PRIMARY", screen: primary.size, barHeight: 146.4),
                       "PRIMARY-2560x1440-146")
        var strips = strips()
        XCTAssertEqual(strips.key(for: magnifiedBar), magnifiedKey)
        XCTAssertEqual(strips.key(for: thumbnailBar(count: 17)), magnifiedKey)
        XCTAssertNotEqual(strips.key(for: thumbnailBar(height: 150)), magnifiedKey)
        XCTAssertNil(strips.key(for: thumbnailBar(on: builtIn)))
    }

    /// The first hover after launch, with a strip kept on disk: every thumbnail's label is drawn from it at once.
    func testAMagnifyingBarsCaptionsAreDrawnFromItsStripWithNoCaptureOfTheirOwn() throws {
        var strips = strips()
        strips.adopt([magnifiedKey: try strip()])
        let drawing = drawn(&strips, hovered: 5, at: 10)
        var looks = CaptionLooks()
        for caption in magnifiedBar.captions {
            let source = MissionControlLabels.lookSource(
                for: caption, on: magnifiedBar, strip: drawing, leaving: nil, looks: &looks)
            guard case .strip(let strip) = source else { return XCTFail("\(caption.covers) not drawn from the strip") }
            XCTAssertEqual(strip.background, "hills")
        }
    }

    /// Labels riding the grow from the names wear the names row's looks until they land. Looks are kept by bar
    /// height: none is ever captured at a magnifying bar's, so looked for there they never come.
    func testALabelRidingTheGrowOntoAMagnifyingBarWearsItsNamesRowLook() throws {
        let names = thumbnailBar(height: 40)
        var looks = CaptionLooks()
        _ = looks.finish(looks.capture(of: [names], attempt: 1),
                         CaptionLooks.Result(found: try found(names.captions, on: names)), moved: false)
        for kept in [nil, try strip()] {
            var strips = strips()
            if let kept { strips.adopt([magnifiedKey: kept]) }
            let drawing = drawn(&strips, hovered: 5, at: 10)
            for (caption, leaving) in zip(magnifiedBar.captions, names.captions) {
                let source = MissionControlLabels.lookSource(
                    for: caption, on: magnifiedBar, strip: drawing, leaving: (names, leaving), looks: &looks)
                guard case .riding(let worn, let from, let onto) = source
                else { return XCTFail("\(caption.covers) riding the grow drawn as \(source)") }
                XCTAssertTrue(worn.exact)
                XCTAssertEqual(worn.look.plain?.top, 7.5)
                XCTAssertEqual(from, leaving.centre)
                XCTAssertTrue(onto?.image === kept?.image)
            }
        }
    }

    // MARK: Riding the grow

    /// macOS's captions ride the grow down from the names sooner than the thumbnails grow: measured in the films of
    /// three expansions, they were 38% of the way at 0.1s after the pointer entered, 73% at 0.15s and there by 0.21s.
    func testLabelsRideTheGrowAsMacOSsCaptionsDo() {
        let timing = DockMotion.growCaptions
        for (time, progress) in [(0.088, 0.274), (0.100, 0.37), (0.121, 0.50), (0.150, 0.71), (0.167, 0.82),
                                 (0.188, 0.89)] {
            XCTAssertEqual(Double(timing.progress(at: time, from: 0)), progress, accuracy: 0.045, "at \(time)s")
        }
        XCTAssertEqual(timing.end(from: 0), 0.208, accuracy: 0.001)
        // The thumbnails' timing, which the labels took before, is a quarter of the way behind at 0.1s.
        XCTAssertLessThan(Double(DockMotion.expand.progress(at: 0.100, from: 0)), 0.15)
    }

    /// Every label rides down, then stays landed under its thumbnail while macOS's captions under the thumbnails
    /// not hovered are there; then only the hovered one's is drawn.
    func testEveryLabelStaysThroughTheGrowUntilMacOSsOtherCaptionsHaveGone() {
        typealias Labels = MissionControlLabels
        XCTAssertEqual(Labels.growPhase(at: 10.1, reference: 10), .riding)
        XCTAssertEqual(Labels.growPhase(at: 10 + DockMotion.growCaptions.end(from: 0) - 0.001, reference: 10), .riding)
        XCTAssertEqual(Labels.growPhase(at: 10 + DockMotion.growCaptions.end(from: 0), reference: 10), .landed)
        // The last frame filmed with them showing came 0.217s after the pointer entered.
        XCTAssertEqual(Labels.growPhase(at: 10.234, reference: 10), .landed)
        XCTAssertEqual(Labels.growPhase(at: 10.25, reference: 10), .over)
    }

    /// A label riding the grow in its names row look starts where that caption was, and lands with its name where
    /// the strip draws it, so it never jumps as it turns into the strip's label.
    func testARidingLabelStartsOverItsCaptionOnTheNamesAndLandsWhereTheStripDrawsIt() throws {
        let look = try XCTUnwrap(try look(top: 7.5).plain)
        let leaving = CGPoint(x: 511, y: 20)
        XCTAssertEqual(MissionControlLabels.rideStart(of: look, leaving: leaving, barTop: 0), CGPoint(x: 468, y: 7.5))
        let strip = try strip()
        let landing = strip.landing(underThumbnailAt: 229, inkOffset: 0.4)
        XCTAssertEqual(landing, CGPoint(x: 229 + 0.5 + 0.4, y: 116 + 18))
        let end = MissionControlLabels.rideEnd(
            of: look, leaving: leaving, centre: CGPoint(x: 229, y: 95), landing: landing, barTop: 0)
        // Its name's ink middle, the image's middle, on the native ink's; its baseline on the native baseline.
        XCTAssertEqual(end.x + look.frame.width / 2, landing.x, accuracy: 0.001)
        XCTAssertEqual(end.y + look.baseline, landing.y, accuracy: 0.001)
        // With no strip, as far from where it started as the Dock's captions are apart.
        let unstripped = MissionControlLabels.rideEnd(
            of: look, leaving: leaving, centre: CGPoint(x: 229, y: 95), landing: nil, barTop: 0)
        XCTAssertEqual(unstripped, CGPoint(x: 229 - 43, y: 7.5 + 75))
    }

    /// With no names row look to wear, a label riding the grow is drawn as the magnifying bar's labels are.
    func testALabelRidingTheGrowWithNoNamesRowLookIsDrawnFromTheStrip() throws {
        let names = thumbnailBar(height: 40)
        var strips = strips()
        strips.adopt([magnifiedKey: try strip()])
        let drawing = drawn(&strips, hovered: 5, at: 10)
        var looks = CaptionLooks()
        let source = MissionControlLabels.lookSource(
            for: magnifiedBar.captions[2], on: magnifiedBar, strip: drawing, leaving: (names, names.captions[2]),
            looks: &looks)
        guard case .strip = source else { return XCTFail("drawn as \(source)") }
    }

    func testABarThatDoesNotMagnifyIsNeverDrawnFromAStrip() throws {
        let fifteen = thumbnailBar(count: 15)
        var looks = CaptionLooks()
        let caption = fifteen.captions[5]
        guard case .awaited = MissionControlLabels.lookSource(
            for: caption, on: fifteen, strip: nil, leaving: nil, looks: &looks)
        else { return XCTFail("a bar that doesn't magnify waits for its caption's own capture") }
        let found = [CaptionLooks.keys(bar: fifteen, caption: caption).exact: try look(top: 127)]
        _ = looks.finish(looks.capture(of: [fifteen], attempt: 1), CaptionLooks.Result(found: found), moved: false)
        guard case .captured(let captured) = MissionControlLabels.lookSource(
            for: caption, on: fifteen, strip: nil, leaving: nil, looks: &looks)
        else { return XCTFail("a bar that doesn't magnify takes its caption's own capture") }
        XCTAssertTrue(captured.exact)
    }

    func testOnlyBarsThatDoNotMagnifyAreCapturedCaptionByCaption() {
        let magnification = learnedToMagnify()
        let names = thumbnailBar(height: 40), fifteen = thumbnailBar(count: 15)
        let captured = MissionControlLabels.barsCapturedByCaption(
            [names, magnifiedBar, fifteen], magnification: magnification)
        XCTAssertEqual(captured.map(\.buttons.count), [16, 15])
        XCTAssertEqual(captured.map(\.captions.count), [16, 15])
        XCTAssertEqual(captured.map(\.frame.height), [40, 146])
    }

    func testACaptureWaitsForTheHoverAndEverythingElseToSettle() throws {
        var strips = strips()
        drawn(&strips, hovered: 5, at: 10)
        XCTAssertNil(due(strips, at: 10.1))
        XCTAssertNotNil(due(strips, at: 10.15))
        XCTAssertNil(due(strips, at: 10.15, steadySince: 10.05))
        drawn(&strips, hovered: 6, at: 10.2)
        XCTAssertNil(due(strips, hovered: 6, at: 10.3))
        XCTAssertNotNil(due(strips, hovered: 6, at: 10.35))
    }

    /// Steady once the bars have been still, and the thumbnails done resizing, for a moment.
    func testCapturesAreSteadyFromTheLaterOfTheBarsStillingAndTheThumbnailsLastResizing() {
        XCTAssertEqual(CaptionStrips.steadySince(stillSince: 9, resizedAt: nil), 9)
        XCTAssertEqual(CaptionStrips.steadySince(stillSince: 9, resizedAt: 10.05), 10.05)
        XCTAssertEqual(CaptionStrips.steadySince(stillSince: 10.1, resizedAt: 10.05), 10.1)
        XCTAssertNil(CaptionStrips.steadySince(stillSince: nil, resizedAt: 10.05))
    }

    /// The thumbnails can move between the last reading and the shot: the first reading after it tells.
    func testACaptureWhoseThumbnailMovedByTheFirstReadingAfterItsShotWasCaughtMoving() throws {
        let start = magnifiedBar.buttons[5].frame
        XCTAssertTrue(CaptionStrips.thumbnailStayed(at: start, now: start))
        XCTAssertTrue(CaptionStrips.thumbnailStayed(at: start, now: start.offsetBy(dx: 0.5, dy: -0.5)))
        XCTAssertFalse(CaptionStrips.thumbnailStayed(at: start, now: start.offsetBy(dx: 0.6, dy: 0)))
        XCTAssertFalse(CaptionStrips.thumbnailStayed(at: start, now: start.insetBy(dx: 0.3, dy: 0)))
        XCTAssertFalse(CaptionStrips.thumbnailStayed(at: start, now: nil))
        var strips = strips()
        let capture = try XCTUnwrap(capture(&strips))
        XCTAssertEqual(capture.thumbnail, start)
        XCTAssertEqual(strips.finish(capture, .strip(try strip()), moved: true, at: 10.2), .moved)
        XCTAssertNil(drawn(&strips, hovered: 5, at: 10.3).strip)
    }

    /// Captures that caught something moving show nothing about whether a strip can be had: only those that fail or
    /// miss count, and four of them and the bar stops waiting for one.
    func testOnlyFailedAndMissedCapturesCountTowardsTheLimit() throws {
        var strips = strips()
        var time: TimeInterval = 10.2
        func attempt(_ result: MissionControlCaptionLook.StripCapture?, moved: Bool) throws -> CaptionStrips.Outcome {
            let capture = try XCTUnwrap(self.capture(&strips, at: time))
            let outcome = strips.finish(capture, result, moved: moved, at: time)
            XCTAssertNil(due(strips, at: time + CaptionStrips.retryDelay - 0.01))
            time += CaptionStrips.retryDelay
            return outcome
        }
        for _ in 0..<10 { XCTAssertEqual(try attempt(.strip(try strip()), moved: true), .moved) }
        XCTAssertTrue(drawn(&strips, hovered: 5, at: 10).awaited)
        XCTAssertEqual(try attempt(nil, moved: false), .failed)
        XCTAssertEqual(try attempt(.missed("contrast 12, not over 40"), moved: false), .missed)
        XCTAssertEqual(try attempt(nil, moved: false), .failed)
        XCTAssertTrue(drawn(&strips, hovered: 5, at: 10).awaited)
        XCTAssertEqual(try attempt(.missed("cut off at the screen's edge"), moved: false), .missed)
        XCTAssertNil(capture(&strips, at: time))
        strips.looksChanged()
        let drawing = drawn(&strips, hovered: 5, at: 10, colors: CaptionLooks.Colors(bar: cgColor(barColor)))
        XCTAssertFalse(drawing.awaited)
        var looks = CaptionLooks()
        guard case .fallback(let fallback) = MissionControlLabels.lookSource(
            for: magnifiedBar.captions[5], on: magnifiedBar, strip: drawing, leaving: nil, looks: &looks)
        else { return XCTFail("no name shown once the strip can't arrive") }
        assertColor(try components(try XCTUnwrap(fallback?.fill)), barColor)
    }

    /// Captures that keep disagreeing with the strip drawn, and each other, stop after their own few.
    func testCapturesHeldHaveTheirOwnLimit() throws {
        var strips = strips()
        strips.adopt([magnifiedKey: try strip()])
        let first = try XCTUnwrap(capture(&strips))
        XCTAssertEqual(strips.finish(first, .strip(try strip(text: (180, 180, 190))), moved: false, at: 10.2), .held)
        let second = try XCTUnwrap(capture(&strips, since: 10.3, at: 10.5))
        XCTAssertEqual(strips.finish(second, .strip(try strip(text: (120, 120, 130))), moved: false, at: 10.5), .held)
        XCTAssertEqual(CaptionStrips.heldLimit, 2)
        XCTAssertNil(capture(&strips, since: 10.6, at: 11))
    }

    /// A strip's captures that failed don't spend the captures that measure its pill, nor the other way about.
    func testCapturesForThePillHaveTheirOwnBudget() throws {
        var strips = strips()
        var time: TimeInterval = 10.2
        for _ in 0..<(CaptionStrips.attemptLimit - 1) {
            let capture = try XCTUnwrap(capture(&strips, at: time))
            XCTAssertEqual(strips.finish(capture, nil, moved: false, at: time), .failed)
            time += CaptionStrips.retryDelay
        }
        for expected in [CaptionStrips.Outcome.drawn, .kept] {
            let capture = try XCTUnwrap(capture(&strips, at: time))
            XCTAssertEqual(strips.finish(capture, .strip(try strip()), moved: false, at: time), expected)
            time += CaptionStrips.retryDelay
        }
        for _ in 0..<CaptionStrips.attemptLimit {
            let capture = try XCTUnwrap(capture(&strips, hovered: 2, current: true, since: time - 0.2, at: time))
            XCTAssertTrue(capture.seeksPill)
            XCTAssertEqual(strips.finish(capture, nil, moved: false, at: time), .failed)
            time += CaptionStrips.retryDelay
        }
        XCTAssertNil(capture(&strips, hovered: 2, current: true, since: time - 0.2, at: time))
    }

    func testAMissIsTriedAgainUnderTheSameThumbnailAfterARest() throws {
        var strips = strips()
        let first = try XCTUnwrap(capture(&strips, hovered: 0))
        XCTAssertEqual(strips.finish(first, .missed("cut off at the screen's edge"), moved: false, at: 10.2),
                       .missed)
        XCTAssertNotNil(due(strips, hovered: 0, at: 10.2 + CaptionStrips.retryDelay, steadySince: 10))
    }

    func testAnotherThumbnailHoveredWhileACaptureRunsMakesItMoved() throws {
        var strips = strips()
        let capture = try XCTUnwrap(capture(&strips))
        drawn(&strips, hovered: 6, at: 10.25)
        XCTAssertEqual(strips.finish(capture, .strip(try strip()), moved: false, at: 10.3), .moved)
        XCTAssertNil(drawn(&strips, hovered: 6, at: 10.3).strip)
    }

    func testABarHoveredForASecondWithNoStripStopsWaitingForOne() {
        var strips = strips()
        XCTAssertTrue(drawn(&strips, hovered: 5, at: 10).awaited)
        XCTAssertTrue(drawn(&strips, hovered: 5, at: 10.6).awaited)
        // Off the bar, the wait stands still.
        drawn(&strips, hovered: nil, at: 10.7)
        drawn(&strips, hovered: nil, at: 15)
        XCTAssertTrue(drawn(&strips, hovered: 6, at: 15.1).awaited)
        XCTAssertTrue(drawn(&strips, hovered: 6, at: 15.49).awaited)
        XCTAssertFalse(drawn(&strips, hovered: 6, at: 15.5).awaited)
    }

    func testAScreenWithNoKnownBackgroundFallsBackAtOnce() {
        var strips = CaptionStrips()
        strips.beginSession(backgrounds: [:], screens: [primaryInfo])
        XCTAssertFalse(drawn(&strips, hovered: 5, at: 10).awaited)
        XCTAssertNil(due(strips, at: 11))
    }

    func testAMagnifyingBarFallsBackToThePlateColoursSeenOnItThenTheNamesRows() throws {
        let names = CaptionLooks.Colors(text: cgColor(namesRowText), bar: cgColor((10, 10, 40)))
        let seen = try XCTUnwrap(CaptionStrips.fallback(seen: sighting(bar: barColor), measured: names, scale: 2))
        assertColor(try components(seen.fill), barColor)
        assertColor(try components(seen.text), textColor)
        XCTAssertEqual(seen.baseline, 133)
        XCTAssertEqual(seen.lineOffset, 1)
        // A capture that saw no bar beside the caption: the names row's colours, placed where it saw the caption.
        let barless = try XCTUnwrap(CaptionStrips.fallback(seen: sighting(bar: nil), measured: names, scale: 2))
        assertColor(try components(barless.fill), (10, 10, 40))
        XCTAssertEqual(barless.baseline, 133)
        let unseen = try XCTUnwrap(CaptionStrips.fallback(seen: nil, measured: names, scale: 2))
        assertColor(try components(unseen.fill), (10, 10, 40))
        assertColor(try components(unseen.text), namesRowText)
        XCTAssertNil(unseen.baseline)
        XCTAssertEqual(unseen.lineOffset, 0)
        // A box only with no bar colour from anywhere.
        XCTAssertNil(CaptionStrips.fallback(seen: nil, measured: CaptionLooks.Colors(text: cgColor(namesRowText)),
                                            scale: 2))
    }

    /// The black box the label fell back to left the native pill showing round it.
    func testAFallbackPlateCoversTheNativePillWhereTheStripWouldCentreTheLabel() throws {
        let fallback = StripFallback(fill: cgColor(barColor), text: cgColor(textColor), baseline: 133, lineOffset: 1.5,
                                     scale: 2)
        let covers = StripNames.Ink(width: 60, offset: 0.4)
        let placed = fallback.plate(nameWidth: 30, covers: covers, thumbnailMidX: 500, captionCentreY: 140, barTop: 4)
        // The native pill, 24pt tall and its text's ink and 11.5pt either side wide, and 2 pixels more all round.
        XCTAssertEqual(placed.plate.size.width, 60 + 23 + 2, accuracy: 0.001)
        XCTAssertEqual(placed.plate.size.height, 24 + 2, accuracy: 0.001)
        XCTAssertEqual(placed.origin.x + placed.plate.size.width / 2, 500 + 1.5 + 0.4, accuracy: 0.001)
        XCTAssertEqual(placed.origin.y, 4 + 133 - 17 - 1, accuracy: 0.001)
        XCTAssertEqual(placed.plate.baseline, 18, accuracy: 0.001)
        assertColor(try components(placed.plate.fill), barColor)
        // A name wider than the native caption widens it.
        let wide = fallback.plate(nameWidth: 90, covers: covers, thumbnailMidX: 500, captionCentreY: 140, barTop: 4)
        XCTAssertEqual(wide.plate.size.width, 90 + 23 + 2, accuracy: 0.001)
        // With no caption seen, centred on the Dock's caption centre.
        let unseen = StripFallback(fill: cgColor(barColor), text: cgColor(textColor), baseline: nil, lineOffset: 0,
                                   scale: 2)
        let centred = unseen.plate(nameWidth: 30, covers: covers, thumbnailMidX: 500, captionCentreY: 140, barTop: 4)
        XCTAssertEqual(centred.origin.y + centred.plate.size.height / 2, 140, accuracy: 0.001)
        XCTAssertEqual(centred.origin.x + centred.plate.size.width / 2, 500.4, accuracy: 0.001)
    }

    /// Whatever became of a capture, what it saw of the bar is kept for the fallback, for as long as the screen shows
    /// the same background.
    func testWhatAnyCaptureSawOfTheBarIsKeptForTheFallback() throws {
        var strips = strips()
        let names = CaptionLooks.Colors(bar: cgColor((10, 10, 40)))
        let capture = try XCTUnwrap(capture(&strips))
        let missed = MissionControlCaptionLook.StripCapture.missed(
            "text left beside the caption", seen: sighting(bar: barColor))
        XCTAssertEqual(strips.finish(capture, missed, moved: false, at: 10.2), .missed)
        let fallback = try XCTUnwrap(drawn(&strips, hovered: 5, at: 10.3, colors: names).fallback)
        assertColor(try components(fallback.fill), barColor)
        XCTAssertEqual(fallback.baseline, 133)
        strips.beginSession(backgrounds: [primaryKey: "hills"], screens: [primaryInfo])
        assertColor(try components(try XCTUnwrap(drawn(&strips, hovered: 5, at: 20, colors: names).fallback?.fill)),
                    barColor)
        strips.beginSession(backgrounds: [primaryKey: "desert"], screens: [primaryInfo])
        assertColor(try components(try XCTUnwrap(drawn(&strips, hovered: 5, at: 30, colors: names).fallback?.fill)),
                    (10, 10, 40))
    }

    func testAStripCapturedOverAnotherBackgroundIsNotDrawn() throws {
        var strips = strips(background: "desert")
        strips.adopt([magnifiedKey: try strip(background: "hills")])
        XCTAssertNil(drawn(&strips, hovered: 5, at: 10).strip)
        XCTAssertNotNil(capture(&strips))
    }

    /// A strip a capture caught moving would be drawn off centre at every launch: the first is drawn at once, there
    /// being none, but kept on disk only once a second capture agrees with it.
    func testAFirstStripIsDrawnAtOnceButKeptOnlyOnceASecondCaptureAgrees() throws {
        var strips = strips()
        let first = try XCTUnwrap(capture(&strips))
        let caught = try strip()
        XCTAssertEqual(strips.finish(first, .strip(caught), moved: false, at: 10.2), .drawn)
        XCTAssertTrue(drawn(&strips, hovered: 5, at: 10.3).strip?.image === caught.image)
        let second = try XCTUnwrap(capture(&strips, since: 10.3, at: 10.5))
        XCTAssertEqual(strips.finish(second, .strip(try strip(lineOffset: 2)), moved: false, at: 10.5), .held)
        let third = try XCTUnwrap(capture(&strips, since: 10.5, at: 10.8))
        XCTAssertEqual(strips.finish(third, .strip(try strip(lineOffset: 1.8)), moved: false, at: 10.8), .kept)
        XCTAssertEqual(strips.kept[magnifiedKey]?.lineOffset, 1.8)
        XCTAssertNil(capture(&strips, hovered: 6, since: 11, at: 11.2))
    }

    func testAStripIsCapturedUntilTwoAgreeAndOnceMoreForThePill() throws {
        var strips = strips()
        let first = try XCTUnwrap(capture(&strips))
        XCTAssertEqual(strips.finish(first, .strip(try strip()), moved: false, at: 10.2), .drawn)
        let second = try XCTUnwrap(capture(&strips, hovered: 6, since: 11, at: 11.2))
        XCTAssertEqual(strips.finish(second, .strip(try strip()), moved: false, at: 11.2), .kept)
        XCTAssertNil(capture(&strips, hovered: 7, since: 11.5, at: 11.7))
        let inPill = try XCTUnwrap(capture(&strips, hovered: 2, current: true, since: 12, at: 12.2))
        XCTAssertEqual(strips.finish(inPill, .strip(try strip(pill: true)), moved: false, at: 12.2), .kept)
        XCTAssertNotNil(drawn(&strips, hovered: 2, at: 12.3).strip?.pill)
        XCTAssertNil(capture(&strips, hovered: 2, current: true, since: 12, at: 12.4))
        // A strip kept from before with its pill measured needs no capture in the pill.
        strips.beginSession(backgrounds: [primaryKey: "hills"], screens: [primaryInfo])
        XCTAssertNotNil(drawn(&strips, hovered: 5, at: 20).strip)
        let next = try XCTUnwrap(capture(&strips, since: 20, at: 20.2))
        XCTAssertEqual(strips.finish(next, .strip(try strip()), moved: false, at: 20.2), .kept)
        XCTAssertNil(capture(&strips, hovered: 2, current: true, since: 21, at: 21.2))
        XCTAssertNotNil(drawn(&strips, hovered: 2, at: 21.3).strip?.pill)
    }

    /// A capture caught as a caption faded measures it dim: it doesn't replace a good strip on its own.
    func testAStripThatDisagreesWithTheOneDrawnIsHeldUntilAnotherAgrees() throws {
        var strips = strips()
        let good = try strip()
        strips.adopt([magnifiedKey: good])
        let dim = (180, 180, 190)
        let first = try XCTUnwrap(capture(&strips))
        XCTAssertEqual(strips.finish(first, .strip(try strip(text: dim)), moved: false, at: 10.2), .held)
        XCTAssertTrue(drawn(&strips, hovered: 5, at: 10.3).strip?.image === good.image)
        XCTAssertTrue(strips.kept[magnifiedKey]?.image === good.image)
        let second = try XCTUnwrap(capture(&strips, since: 10.3, at: 10.5))
        let agreeing = try strip(text: (182, 181, 191))
        XCTAssertEqual(strips.finish(second, .strip(agreeing), moved: false, at: 10.5), .kept)
        XCTAssertTrue(strips.kept[magnifiedKey]?.image === agreeing.image)
    }

    func testAStripThatAgreesWithTheOneDrawnReplacesItAtOnce() throws {
        var strips = strips()
        strips.adopt([magnifiedKey: try strip()])
        let capture = try XCTUnwrap(capture(&strips))
        let fresh = try strip(text: (243, 244, 251))
        XCTAssertEqual(strips.finish(capture, .strip(fresh), moved: false, at: 10.2), .kept)
        XCTAssertTrue(drawn(&strips, hovered: 5, at: 10.3).strip?.image === fresh.image)
    }

    func testAStripCaptureFromAnEarlierSessionIsIgnored() throws {
        var strips = strips()
        let capture = try XCTUnwrap(capture(&strips))
        strips.beginSession(backgrounds: [primaryKey: "hills"], screens: [primaryInfo])
        XCTAssertEqual(strips.finish(capture, .strip(try strip()), moved: false, at: 10.2), .stale)
        XCTAssertNil(drawn(&strips, hovered: 5, at: 10.3).strip)
    }

    func testStripsReadFromDiskNeverReplaceOnesCapturedThisRun() throws {
        var strips = strips()
        let capture = try XCTUnwrap(capture(&strips))
        _ = strips.finish(capture, .strip(try strip()), moved: false, at: 10.2)
        strips.adopt([magnifiedKey: try strip(height: 30)])
        XCTAssertEqual(drawn(&strips, hovered: 5, at: 10.3).strip?.height, 26)
    }

    /// The style is worked out once, not every frame, until the strip or the looks change.
    func testAStripsStyleIsWorkedOutOnceUntilTheLooksChange() throws {
        var strips = strips()
        var asked = 0
        func draw(at time: TimeInterval) -> StripDrawing {
            strips.drawing(for: magnifiedBar, hovered: 5, colors: {
                asked += 1
                return CaptionLooks.Colors(pill: self.cgColor(self.namesRowPill))
            }, at: time)
        }
        _ = draw(at: 10)
        _ = draw(at: 10.02)
        XCTAssertEqual(asked, 1)
        strips.looksChanged()
        XCTAssertNotNil(draw(at: 10.04).style.pill)
        XCTAssertEqual(asked, 2)
        strips.adopt([magnifiedKey: try strip(pill: true)])
        XCTAssertEqual(draw(at: 10.06).style.pill, try strip(pill: true).pill)
        XCTAssertEqual(asked, 3)
    }

    func testAStripSurvivesTheTripToDisk() throws {
        let kept = try strip(pill: true)
        let read = try XCTUnwrap(CaptionStripStore.decode(try XCTUnwrap(CaptionStripStore.encode(kept))))
        XCTAssertEqual(read.image.width, kept.image.width)
        XCTAssertEqual(read.image.height, kept.image.height)
        XCTAssertEqual([read.scale, read.top, read.baseline, read.lineOffset, read.text.fontSize],
                       [2, 116, 18, 0.5, 14])
        XCTAssertEqual(read.background, "hills")
        assertColor(try components(read.text.color), textColor)
        assertColor(try components(try XCTUnwrap(read.pill?.color)), pillColor)
        XCTAssertEqual(read.pill?.padding, 11.5)
        assertColor(try pixels(read.image)[10][400], barColor)
    }

    // MARK: - Kept across launches

    /// What a run learns of the magnified bar, on the primary display known by its UUID.
    private func magnificationLearned() -> BarMagnification {
        var magnification = BarMagnification()
        magnification.know([primaryInfo])
        _ = magnification.learn(from: magnifiedBar, read: 10, pointer: overSixth, at: 10)
        return magnification
    }

    func testWhatIsLearnedOfABarSurvivesTheTripToDiskByDisplayUUID() throws {
        let kept = magnificationLearned().kept
        XCTAssertEqual(kept, ["PRIMARY|2560|16": .magnifies])
        let stored = try XCTUnwrap(BarMagnificationStore.encode(kept))
        XCTAssertEqual(BarMagnificationStore.decode(stored), kept)
        let notMagnifying: [String: BarMagnification.Learned] = ["PRIMARY|2560|15": .doesNotMagnify]
        let other = try XCTUnwrap(BarMagnificationStore.encode(notMagnifying))
        XCTAssertEqual(BarMagnificationStore.decode(other), notMagnifying)
    }

    /// The first session after a launch: macOS captions only the hovered thumbnail from the first frame of the grow.
    func testABarKnownToMagnifyBeforeALaunchShowsOnlyTheHoveredLabelFromItsFirstFrame() throws {
        let stored = try XCTUnwrap(BarMagnificationStore.decode(
            try XCTUnwrap(BarMagnificationStore.encode(magnificationLearned().kept))))
        var launched = BarMagnification()
        launched.know([primaryInfo])
        XCTAssertEqual(ShownLabels.on(magnifiedBar, magnifies: launched.magnifies(magnifiedBar), pointer: overSixth),
                       .all)
        launched.adopt(stored)
        XCTAssertTrue(launched.magnifies(magnifiedBar))
        XCTAssertEqual(
            ShownLabels.on(magnifiedBar, magnifies: launched.magnifies(magnifiedBar), pointer: overSixth).hovered, 5)
        XCTAssertFalse(launched.magnifies(thumbnailBar(count: 15)))
    }

    func testWhatThisRunLearnedOfABarBeatsWhatWasKept() {
        var magnification = magnificationLearned()
        magnification.adopt(["PRIMARY|2560|16": .doesNotMagnify])
        XCTAssertTrue(magnification.magnifies(magnifiedBar))
    }

    /// A display's ID can change from one launch to the next: a bar on a display with no known UUID is kept for the
    /// run only.
    func testABarOnADisplayWithNoKnownUUIDIsKeptOnlyForTheRun() {
        var magnification = BarMagnification()
        _ = magnification.learn(from: magnifiedBar, read: 10, pointer: overSixth, at: 10)
        XCTAssertTrue(magnification.magnifies(magnifiedBar))
        XCTAssertTrue(magnification.kept.isEmpty)
    }

    private var primaryLooksFile: String { CaptionLookStore.file(display: "PRIMARY", screen: primary.size) }

    /// The names row's looks a run captured on the primary screen over `background`, `top` below the bar's top.
    private func namesRowLooks(over background: String = "hills", top: CGFloat = 7.5) throws -> CaptionLooks {
        var looks = CaptionLooks()
        var found: [String: NativeCaptionLook] = [:]
        for caption in mainBar.captions {
            var made = try look(top: top)
            made.textColor = cgColor(namesRowText)
            made.barColor = cgColor((10, 10, 40))
            found[CaptionLooks.keys(bar: mainBar, caption: caption).exact] = made
        }
        _ = looks.finish(looks.capture(of: [mainBar], attempt: 1),
                         CaptionLooks.Result(found: found, backgrounds: [primaryKey: background]), moved: false)
        return looks
    }

    /// The names row's looks as read back from disk after a launch.
    private func namesRowLooksFromDisk(over background: String = "hills") throws -> [String: CaptionLooks.ScreenLooks] {
        let kept = try XCTUnwrap(try namesRowLooks(over: background).screenLooks(primaryKey))
        let read = try XCTUnwrap(CaptionLookStore.decode(try XCTUnwrap(CaptionLookStore.encode(kept))))
        return [primaryLooksFile: read]
    }

    func testAScreensLooksSurviveTheTripToDiskWithTheirBackground() throws {
        let kept = try XCTUnwrap(try namesRowLooks().screenLooks(primaryKey))
        XCTAssertEqual(kept.entries.map(\.exact), ["Desktop 1|Mail|40", "Desktop 2|Code|40"])
        XCTAssertEqual(kept.entries.map(\.name), ["Mail|40", "Code|40"])
        let read = try XCTUnwrap(CaptionLookStore.decode(try XCTUnwrap(CaptionLookStore.encode(kept))))
        XCTAssertEqual(read.background, "hills")
        XCTAssertEqual(read.entries.map(\.exact), kept.entries.map(\.exact))
        XCTAssertEqual(read.entries.map(\.name), kept.entries.map(\.name))
        let look = try XCTUnwrap(read.entries.first?.look)
        let plain = try XCTUnwrap(look.plain)
        XCTAssertEqual(plain.top, 7.5)
        XCTAssertEqual(plain.frame, CGRect(x: -43, y: -12.5, width: 86, height: 25))
        XCTAssertEqual(plain.image.width, 1)
        assertColor(try components(try XCTUnwrap(look.textColor)), namesRowText)
        assertColor(try components(try XCTUnwrap(look.barColor)), (10, 10, 40))
        XCTAssertNil(look.pillColor)
        XCTAssertNil(CaptionLooks().screenLooks(primaryKey))
    }

    /// The first session after a launch: the names row's labels are drawn from their first frame, with no capture.
    func testNamesRowCaptionsTakeTheirLooksFromDiskWithNoCapture() throws {
        var looks = CaptionLooks()
        XCTAssertEqual(looks.adopt(try namesRowLooksFromDisk(), screens: [primaryInfo], current: [primaryKey: "hills"]),
                       2)
        for caption in mainBar.captions {
            guard case .captured(let found) = MissionControlLabels.lookSource(
                for: caption, on: mainBar, strip: nil, leaving: nil, looks: &looks)
            else { return XCTFail("\(caption.name) has no look") }
            XCTAssertTrue(found.exact)
            XCTAssertEqual(found.look.plain?.top, 7.5)
        }
        assertColor(try components(try XCTUnwrap(looks.measuredColors(onScreen: primaryKey, height: 146).bar)),
                    (10, 10, 40))
    }

    /// After a wallpaper or appearance change, what was kept shows another background: the native captions show
    /// until captured again.
    func testLooksKeptOverAnotherBackgroundAreNotDrawn() throws {
        var looks = CaptionLooks()
        XCTAssertEqual(looks.adopt(try namesRowLooksFromDisk(), screens: [primaryInfo],
                                   current: [primaryKey: "desert"]), 0)
        guard case .awaited = MissionControlLabels.lookSource(
            for: mail, on: mainBar, strip: nil, leaving: nil, looks: &looks)
        else { return XCTFail("a look kept over another background drawn") }
    }

    func testLooksThisRunCapturedBeatThoseKept() throws {
        var looks = CaptionLooks()
        var found: [String: NativeCaptionLook] = [:]
        found[CaptionLooks.keys(bar: mainBar, caption: mail).exact] = try look(top: 9)
        _ = looks.finish(looks.capture(of: [bar(primary, [mail])], attempt: 1),
                         CaptionLooks.Result(found: found, backgrounds: [primaryKey: "hills"]), moved: false)
        XCTAssertEqual(looks.adopt(try namesRowLooksFromDisk(), screens: [primaryInfo], current: [primaryKey: "hills"]),
                       1)
        XCTAssertEqual(looks.look(for: mail, on: mainBar)?.look.plain?.top, 9)
        XCTAssertEqual(looks.look(for: code, on: mainBar)?.look.plain?.top, 7.5)
        // Captured this run over another background than those kept: none taken.
        var repainted = try namesRowLooks(over: "desert", top: 9)
        XCTAssertEqual(repainted.adopt(try namesRowLooksFromDisk(), screens: [primaryInfo],
                                       current: [primaryKey: "hills"]), 0)
    }

    /// A screen's looks are kept by its display and size: wherever the display is arranged, but not at another size.
    func testLooksAreKeptByDisplayAndScreenSize() throws {
        let moved = ScreenInfo(frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), displayID: 7,
                               uuid: "PRIMARY", scale: 2)
        let movedKey = CaptionLooks.screenKey(moved.frame)
        var looks = CaptionLooks()
        XCTAssertEqual(looks.adopt(try namesRowLooksFromDisk(), screens: [moved], current: [movedKey: "hills"]), 2)
        let movedBar = bar(moved.frame, [mail])
        XCTAssertEqual(looks.look(for: mail, on: movedBar)?.exact, true)
        let resized = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), displayID: 1, uuid: "PRIMARY",
                                 scale: 2)
        var other = CaptionLooks()
        XCTAssertEqual(other.adopt(try namesRowLooksFromDisk(), screens: [resized], current: [primaryKey: "hills"]), 0)
    }

    // MARK: - Motion recording

    func testDrawnLabelsAreLoggedByKeyAtTheirFrames() {
        let labels = [
            DrawnLabel(key: "12", frame: CGRect(x: 1180.5, y: -4, width: 76.5, height: 20)),
            DrawnLabel(key: "7", frame: CGRect(x: 2600, y: 1023.04, width: 80, height: 22)),
        ]
        XCTAssertEqual(
            MissionControlMotionRecorder.drawnLine(labels),
            "ours 12@1180.5,-4.0,76.5,20.0 7@2600.0,1023.0,80.0,22.0")
    }

    func testAFrameWithNoLabelsIsStillLogged() {
        XCTAssertEqual(MissionControlMotionRecorder.drawnLine([]), "ours")
    }

    /// Left out as an application, Spaceman's windows made after a film starts are left out too.
    func testTheFilmOfMacOSAloneLeavesOutSpacemanItself() {
        let applications: [(pid: pid_t, name: String)] = [(1, "Dock"), (getpid(), "Spaceman"), (2, "Finder")]
        XCTAssertEqual(MissionControlMotionRecorder.spaceman(among: applications) { $0.pid }.map(\.name), ["Spaceman"])
    }

    func testTheFilmedBandIs150PointsUnlessAskedOtherwise() {
        XCTAssertEqual(MissionControlMotionRecorder.band(0, displayHeight: 1440), 150)
        XCTAssertEqual(MissionControlMotionRecorder.band(-20, displayHeight: 1440), 150)
        XCTAssertEqual(MissionControlMotionRecorder.band(80, displayHeight: 1440), 80)
    }

    func testTheFilmedBandIsEven() {
        XCTAssertEqual(MissionControlMotionRecorder.band(151, displayHeight: 1440), 152)
        XCTAssertEqual(MissionControlMotionRecorder.band(100.4, displayHeight: 1440), 100)
        XCTAssertEqual(MissionControlMotionRecorder.band(0.5, displayHeight: 1440), 2)
    }

    func testTheFilmedBandStaysWithinTheDisplay() {
        XCTAssertEqual(MissionControlMotionRecorder.band(5000, displayHeight: 1440), 1440)
        XCTAssertEqual(MissionControlMotionRecorder.band(5000, displayHeight: 1117), 1116)
    }

    func testTheTallyWaitsForItsInterval() {
        var tally = FrameTally(name: "video", interval: 5)
        XCTAssertNil(tally.count(.complete(shown: 10, written: true), at: 10.01))
        XCTAssertNil(tally.count(.idle, at: 14.9))
    }

    func testTheTallySumsUpEachInterval() {
        var tally = FrameTally(name: "video", interval: 5)
        _ = tally.count(.complete(shown: 10, written: true), at: 10.01)
        _ = tally.count(.complete(shown: 10.05, written: false), at: 10.07)
        _ = tally.count(.idle, at: 12)
        _ = tally.count(.other, at: 13)
        XCTAssertEqual(
            tally.count(.complete(shown: 15, written: true), at: 15.01),
            "video tally 5.0s: 3 complete, 1 idle, 1 other, 1 unwritten, longest gap 4950.0ms, "
                + "longest delay 20.0ms")
    }

    func testTheTallyStartsAfreshAfterEachSummaryButCarriesTheGapOn() {
        var tally = FrameTally(name: "video", interval: 5)
        _ = tally.count(.complete(shown: 10, written: true), at: 10.01)
        _ = tally.count(.idle, at: 15.01)
        XCTAssertNil(tally.count(.complete(shown: 15.1, written: true), at: 15.11))
        XCTAssertEqual(
            tally.summary(at: 16),
            "video tally 0.9s: 1 complete, 0 idle, 0 other, 0 unwritten, longest gap 5100.0ms, "
                + "longest delay 10.0ms")
        XCTAssertNil(tally.summary(at: 17))
    }

    func testTheTallyIsNamedForItsFilmInEverySummary() {
        var tally = FrameTally(name: "shown", interval: 5)
        _ = tally.count(.complete(shown: 10, written: true), at: 10.01)
        XCTAssertEqual(
            tally.summary(at: 11),
            "shown tally 1.0s: 1 complete, 0 idle, 0 other, 0 unwritten, longest gap 0.0ms, longest delay 10.0ms")
        _ = tally.count(.idle, at: 12)
        XCTAssertEqual(
            tally.summary(at: 12.5),
            "shown tally 0.5s: 0 complete, 1 idle, 0 other, 0 unwritten, longest gap 0.0ms, longest delay 0.0ms")
    }

    func testABarReadingLogsEveryButtonsRawFrameByBar() {
        let line = SpacesBarProbe.line("wm", bars: [
            [(title: "Desktop 1", frame: CGRect(x: 1180.26, y: 60, width: 120, height: 77.04)),
             (title: "Mail", frame: CGRect(x: 1310, y: 60, width: 120, height: 77))],
            [(title: "Desktop 1", frame: CGRect(x: 3424, y: 940.5, width: 96, height: 24))],
        ])
        XCTAssertEqual(
            line, "wm Desktop 1@1180.3,60.0,120.0,77.0 Mail@1310.0,60.0,120.0,77.0 "
                + "| Desktop 1@3424.0,940.5,96.0,24.0")
    }

    func testACaptureReportSaysWhatMatchedAndWhyTheRestMissed() throws {
        let captions = Array(syntheticCaptions) + [
            CaptionToMatch(key: "silent", centre: CGPoint(x: 400, y: 20), barTop: 0, barBottom: 40, maxWidth: 96,
                           covers: "Desktop 4", name: "Quiet"),
        ]
        let matches = MissionControlCaptionLook.Matches(
            looks: ["current": try look(top: 7.5), "other": try look(top: 7.5)],
            misses: ["empty": "contrast 0, not over 40"])
        let report = CaptureReport(displayID: 2, asked: 10, taken: 10.0124, captions: captions, matches: matches)
        XCTAssertEqual(
            report.line(attempt: 1, outcome: .kept, moved: false),
            "capture display 2 attempt 1 kept, bars at rest, bar h 40, shot in 12ms: "
                + "matched \"Desktop 1\" h 25.0, \"Desktop 2\" h 25.0; "
                + "missed \"Desktop 3\" (contrast 0, not over 40), \"Desktop 4\" (no reason given)")
    }

    func testACaptureReportSaysWhenTheBarsMovedAndNothingMatched() {
        let report = CaptureReport(displayID: 1, asked: 5, taken: 5.03, captions: Array(syntheticCaptions.prefix(1)),
                                   matches: .init(misses: ["current": "cut off at the screen's edge"]))
        XCTAssertEqual(
            report.line(attempt: 4, outcome: .moved, moved: true),
            "capture display 1 attempt 4 moved, bars moved, bar h 40, shot in 30ms: matched none; "
                + "missed \"Desktop 1\" (cut off at the screen's edge)")
    }
}
