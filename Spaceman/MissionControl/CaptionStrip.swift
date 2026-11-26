//
//  CaptionStrip.swift
//  Spaceman
//
//  A magnifying Spaces Bar's caption row as plain bar, which every thumbnail's label there is drawn from.
//

import AppKit
import CoreText

/// A magnifying bar's caption row, captured across its screen's width with its one native caption erased. macOS
/// captions only the hovered thumbnail there, at the same depth whatever the thumbnail's size, and the bar's
/// background stays put as the thumbnails resize: any thumbnail's label is the strip cropped where the label sits,
/// with its name over it.
struct CaptionStrip {

    struct TextStyle: Hashable {
        let fontSize: CGFloat
        let color: CGColor
    }

    /// The current space's pill, in points: how far it reaches beyond the text's ink either side, and above and
    /// below the baseline.
    struct PillStyle: Hashable {
        let padding: CGFloat
        let above: CGFloat
        let below: CGFloat
        let color: CGColor
    }

    /// How a magnifying bar's labels are drawn: their text, and the current space's pill, if its colour is known.
    struct Style: Hashable {
        let text: TextStyle
        let pill: PillStyle?
    }

    /// The bar, its left edge the screen's, at `scale` pixels to the point.
    let image: CGImage
    let scale: CGFloat
    /// The strip's top below the bar's top, and the captions' baseline below the strip's top, in points.
    let top: CGFloat
    let baseline: CGFloat
    /// The text of the caption erased from it, and its pill, if it was the current space's.
    let text: TextStyle
    let pill: PillStyle?
    /// What its screen showed behind the bar when it was captured, as `CaptionLooks.currentBackgrounds()` says.
    let background: String

    var height: CGFloat { CGFloat(image.height) / scale }

    /// Where a strip is kept: by display, the screen's size in points and the bar's height. Those decide how deep in
    /// the bar the captions sit and what lies behind them; the number of thumbnails doesn't, so 16 desktops and 17
    /// share a strip. Safe as a file name.
    static func key(display: String, screen: CGSize, barHeight: CGFloat) -> String {
        "\(display)-\(Int(screen.width.rounded()))x\(Int(screen.height.rounded()))-\(Int(barHeight.rounded()))"
    }

    /// This strip, taking `older`'s pill where it measured none and `older` was captured over the same background.
    func keepingPill(of older: CaptionStrip?) -> CaptionStrip {
        guard pill == nil, let older, older.background == background, let kept = older.pill else { return self }
        return CaptionStrip(image: image, scale: scale, top: top, baseline: baseline, text: text, pill: kept,
                            background: background)
    }

    /// How labels are drawn from `strip`: in its caption's text, or until a caption has been measured, the native
    /// caption's 14pt in the text colour `measured` on the screen, white where none was. The current space's pill is
    /// the strip's, or else the native pill in the pill colour `measured` on the screen; none if neither is known.
    static func style(of strip: CaptionStrip?, measured: CaptionLooks.Colors) -> Style {
        let text = strip?.text ?? TextStyle(
            fontSize: MissionControlCaptionLook.nativeFontSize,
            color: measured.text ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let pill = strip?.pill ?? measured.pill.map {
            PillStyle(padding: MissionControlCaptionLook.pillPadding, above: MissionControlCaptionLook.bandAbove,
                      below: MissionControlCaptionLook.bandBelow, color: $0)
        }
        return Style(text: text, pill: pill)
    }

    /// Where a label `width` points wide, centred on `centreX`, goes on a screen whose left edge is at `screenLeft`,
    /// moved onto whole pixels; and the part of the strip behind it, in the unit coordinates of a layer's
    /// `contentsRect`.
    func placement(centreX: CGFloat, width: CGFloat, screenLeft: CGFloat) -> (left: CGFloat, crop: CGRect) {
        let left = ((centreX - width / 2 - screenLeft) * scale).rounded()
        let imageWidth = CGFloat(image.width)
        return (screenLeft + left / scale,
                CGRect(x: left / imageWidth, y: 0, width: width * scale / imageWidth, height: 1))
    }

    /// A label drawn from this strip: as tall as the strip and wide enough to hide the native caption, `coversWidth`
    /// of ink, in its pill and to hold `name`, with the name on the captions' baseline and, for the current space, a
    /// pill half a pixel larger all round than the native one would be.
    func layout(name: NameImage, coversWidth: CGFloat, style: Style, current: Bool) -> StripFace.Layout {
        let pixel = 1 / scale
        func snapped(_ points: CGFloat) -> CGFloat { (points * scale).rounded() / scale }
        let padding = style.pill?.padding ?? MissionControlCaptionLook.pillPadding
        let content = max(name.inkWidth, coversWidth) + 2 * padding
        let width = ((content + 2 * pixel) * scale).rounded(.up) / scale
        let nameFrame = CGRect(
            origin: CGPoint(x: snapped(width / 2 - name.inkMidX), y: snapped(baseline - name.baseline)),
            size: name.size)
        let pill = current ? style.pill.map { pill in
            StripFace.Pill(
                frame: CGRect(x: (width - content - pixel) / 2, y: baseline - pill.above - pixel / 2,
                              width: content + pixel, height: pill.above + pill.below + pixel),
                color: pill.color)
        } : nil
        return StripFace.Layout(size: CGSize(width: width, height: height), nameFrame: nameFrame, pill: pill)
    }
}

/// A label drawn from a caption strip, for the overlay: the strip, the part of it behind the label, the name drawn
/// over it and how they are laid out.
struct StripFace: Equatable {

    struct Pill: Equatable {
        let frame: CGRect
        let color: CGColor
    }

    /// In points from the label's top-left, y down.
    struct Layout: Equatable {
        let size: CGSize
        let nameFrame: CGRect
        let pill: Pill?
    }

    let strip: CGImage
    let crop: CGRect
    let name: CGImage
    let layout: Layout

    static func == (lhs: StripFace, rhs: StripFace) -> Bool {
        lhs.strip === rhs.strip && lhs.name === rhs.name && lhs.crop == rhs.crop && lhs.layout == rhs.layout
    }
}

/// A name drawn on clear in a caption's text, to go over any part of a strip.
struct NameImage {
    let image: CGImage
    /// In points: the image's size, the ink's width and middle from the image's left, and the baseline below its top.
    let size: CGSize
    let inkWidth: CGFloat
    let inkMidX: CGFloat
    let baseline: CGFloat

    /// Room around the ink for its antialiased edge.
    private static let margin: CGFloat = 1

    static func render(_ name: String, style: CaptionStrip.TextStyle, scale: CGFloat) -> NameImage? {
        let line = MissionControlCaptionLook.textLine(name, size: style.fontSize, color: style.color)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = Int(((ink.width + 2 * margin) * scale).rounded(.up))
        let height = Int(((ink.height + 2 * margin) * scale).rounded(.up))
        let space = style.color.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard width > 0, height > 0, let space, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        // Core Graphics' y runs up: the baseline sits `margin` above the ink's lowest point.
        let baselineUp = margin - ink.minY
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: margin - ink.minX, y: baselineUp)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return NameImage(image: image, size: size, inkWidth: ink.width, inkMidX: margin + ink.width / 2,
                         baseline: size.height - baselineUp)
    }
}

/// The names drawn over strips, each rendered once in a text style at a scale, and the native captions' ink widths.
struct StripNames {

    private struct Key: Hashable {
        let text: String
        let style: CaptionStrip.TextStyle
        let scale: CGFloat
    }

    private struct InkKey: Hashable {
        let text: String
        let fontSize: CGFloat
    }

    /// Past this many, the names start afresh: old styles' names would otherwise pile up.
    private static let limit = 512

    private var images: [Key: NameImage] = [:]
    private var inkWidths: [InkKey: CGFloat] = [:]

    mutating func image(for name: String, style: CaptionStrip.TextStyle, scale: CGFloat) -> NameImage? {
        let key = Key(text: name, style: style, scale: scale)
        if let image = images[key] { return image }
        guard let image = NameImage.render(name, style: style, scale: scale) else { return nil }
        if images.count >= Self.limit { images = [:] }
        images[key] = image
        return image
    }

    mutating func inkWidth(of text: String, style: CaptionStrip.TextStyle) -> CGFloat {
        let key = InkKey(text: text, fontSize: style.fontSize)
        if let width = inkWidths[key] { return width }
        let width = MissionControlCaptionLook.inkBounds(of: text, size: style.fontSize).width
        if inkWidths.count >= Self.limit { inkWidths = [:] }
        inkWidths[key] = width
        return width
    }
}
