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
/// with its name over it. macOS draws no pill there, the current space's caption included: its thumbnail's border
/// marks it (filmed on macOS 26.7).
struct CaptionStrip {

    struct TextStyle: Hashable {
        let fontSize: CGFloat
        let color: CGColor
    }

    /// The bar, its left edge the screen's, at `scale` pixels to the point.
    let image: CGImage
    let scale: CGFloat
    /// The strip's top below the screen's top, and the captions' baseline below the strip's top, in points.
    let top: CGFloat
    let baseline: CGFloat
    /// How far right of its thumbnail's middle macOS centres a caption's line of text, in points.
    let lineOffset: CGFloat
    /// The text of the caption erased from it.
    let text: TextStyle
    /// What its screen showed behind the bar when it was captured, as `CaptionLooks.currentBackgrounds()` says.
    let background: String

    var height: CGFloat { CGFloat(image.height) / scale }

    /// The text colour where none was measured: about the native captions' on a dark bar.
    static let unmeasuredText = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Where a strip is kept: by display, the screen's size in points and the bar's height. Those decide how deep in
    /// the bar the captions sit and what lies behind them; the number of thumbnails doesn't, so 16 desktops and 17
    /// share a strip. Safe as a file name.
    static func key(display: String, screen: CGSize, barHeight: CGFloat) -> String {
        "\(display)-\(Int(screen.width.rounded()))x\(Int(screen.height.rounded()))-\(Int(barHeight.rounded()))"
    }

    /// How far apart, 0-255 in sRGB, two captures' colours may be and still agree, their text sizes in points, and
    /// where they have macOS centre a caption, in points.
    static let colorAgreement: CGFloat = 10
    static let sizeAgreement: CGFloat = 0.5
    static let lineAgreement: CGFloat = 1

    /// Whether `other` measured the captions as this did: text of the same size and colour, centred as far off its
    /// thumbnail's middle. A capture taken as a caption faded in or out measures them dimmer; one taken as the
    /// thumbnails moved puts them off centre.
    func agrees(with other: CaptionStrip) -> Bool {
        abs(text.fontSize - other.text.fontSize) <= Self.sizeAgreement
            && abs(lineOffset - other.lineOffset) <= Self.lineAgreement
            && Self.colorsAgree(text.color, other.text.color)
    }

    private static func colorsAgree(_ first: CGColor, _ second: CGColor) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let one = first.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              let two = second.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              one.count >= 3, two.count >= 3
        else { return false }
        let distance = (0..<3).map { pow((one[$0] - two[$0]) * 255, 2) }.reduce(0, +).squareRoot()
        return distance <= colorAgreement
    }

    /// Where a label lands under the thumbnail whose middle is at `mid`, its native text's ink `inkOffset` from
    /// its advance's middle: the middle of that ink across, and the baseline below the bar's top.
    func landing(underThumbnailAt mid: CGFloat, inkOffset: CGFloat) -> CGPoint {
        CGPoint(x: inkCentre(underThumbnailAt: mid, inkOffset: inkOffset), y: top + baseline)
    }

    /// Where the ink of the native caption under the thumbnail whose middle is at `thumbnailMidX` sits, given how far
    /// right of the middle of its advance its ink's middle lies.
    func inkCentre(underThumbnailAt thumbnailMidX: CGFloat, inkOffset: CGFloat) -> CGFloat {
        thumbnailMidX + lineOffset + inkOffset
    }

    /// The text labels are drawn from `strip` in: its caption's, or until a caption has been measured, the native
    /// caption's 14pt in the text colour `measured` on the screen, white where none was.
    static func style(of strip: CaptionStrip?, measured: CaptionLooks.Colors) -> TextStyle {
        strip?.text ?? TextStyle(
            fontSize: MissionControlCaptionLook.nativeFontSize, color: measured.text ?? unmeasuredText)
    }

    /// Where a label laid out as `layout`, centred on `centreX`, goes on a screen whose left edge is at `screenLeft`,
    /// moved onto whole pixels; and the part of the strip behind it, in unit coordinates from the strip's top-left.
    func placement(centreX: CGFloat, layout: StripFace.Layout, screenLeft: CGFloat) -> (left: CGFloat, crop: CGRect) {
        let width = layout.size.width
        let left = ((centreX - width / 2 - screenLeft) * scale).rounded()
        let imageWidth = CGFloat(image.width)
        return (screenLeft + left / scale,
                CGRect(x: left / imageWidth, y: layout.cut / height, width: width * scale / imageWidth,
                       height: layout.size.height / height))
    }

    /// A label drawn from this strip, centred on the native caption's ink: as tall as the strip, less what reaches
    /// above `ceiling` below the bar's top, and wide enough to hide that caption, `coversWidth` of ink, as a pill would
    /// hold it with 2 pixels more either side, and to hold `name`; with the name on the captions' baseline.
    func layout(name: NameImage, coversWidth: CGFloat, ceiling: CGFloat = 0) -> StripFace.Layout {
        let pixel = 1 / scale
        func snapped(_ points: CGFloat) -> CGFloat { (points * scale).rounded() / scale }
        let content = max(name.inkWidth, coversWidth) + 2 * MissionControlCaptionLook.pillPadding
        let width = ((content + 5 * pixel) * scale).rounded(.up) / scale
        let cut = min(max(((ceiling - top) * scale).rounded(.up) / scale, 0), baseline)
        let nameFrame = CGRect(
            origin: CGPoint(x: snapped(width / 2 - name.inkMidX), y: snapped(baseline - name.baseline) - cut),
            size: name.size)
        return StripFace.Layout(size: CGSize(width: width, height: height - cut), nameFrame: nameFrame, cut: cut)
    }

    /// How far below a magnifying bar's top, the bar `barHeight` tall on a screen of `screen`'s size, a label's plate
    /// may start under a thumbnail `thumbnailWidth` wide without cutting into it, its space `current` or not. macOS
    /// draws the thumbnails centred down the bar and as tall for their width as their screen, the current space's in a
    /// border `currentBorder` outside it, which a plate keeps a point clear of. Filmed on macOS 26.7: at their
    /// smallest, 126.7pt wide, the thumbnails ran 37-109pt below the 146pt bar's top; the current space's at its
    /// largest, 160pt wide, ran 28-118pt, its border to 122pt, and macOS's caption's ink below 127pt.
    static func plateCeiling(
        underThumbnailWidth thumbnailWidth: CGFloat, barHeight: CGFloat, screen: CGSize, current: Bool
    ) -> CGFloat {
        guard screen.width > 0 else { return 0 }
        let bottom = (barHeight + thumbnailWidth * screen.height / screen.width) / 2
        return current ? bottom + currentBorder + 1 : bottom
    }

    static let currentBorder: CGFloat = 4
}

/// What a capture saw of a magnifying bar's hovered caption, whether or not it gave a strip: the bar's colour beside
/// it, its text's colour, its baseline below the bar's top, and how far right of its thumbnail's middle macOS centred
/// its line, unless the capture caught the thumbnails moving.
struct CaptionSighting {
    let barColor: CGColor?
    let textColor: CGColor
    let baseline: CGFloat
    let lineOffset: CGFloat?
}

/// A magnifying bar's labels with no strip to draw: plates of the bar's colour, as large as a native pill would be
/// and 2 pixels more all round, with the name in the native caption's text. Placed where the strip would place them
/// as far as that is known: by the baseline and line offset a capture saw, else on the Dock's caption centre.
struct StripFallback: Equatable {
    let fill: CGColor
    let text: CGColor
    let baseline: CGFloat?
    let lineOffset: CGFloat
    let scale: CGFloat

    /// The plate for a label whose name is `nameWidth` of ink over a native caption of `covers`, under the thumbnail
    /// whose middle is at `thumbnailMidX`, the Dock putting the caption's centre at `captionCentreY`, on a bar whose
    /// top is at `barTop`; and its top-left, in AX coordinates.
    func plate(
        nameWidth: CGFloat, covers: StripNames.Ink, thumbnailMidX: CGFloat, captionCentreY: CGFloat, barTop: CGFloat,
        ceiling: CGFloat = 0
    ) -> (plate: LabelPlate, origin: CGPoint) {
        let margin = 2 / scale
        let above = MissionControlCaptionLook.bandAbove + margin
        let full = CGSize(
            width: max(nameWidth, covers.width) + 2 * MissionControlCaptionLook.pillPadding + 2 * margin,
            height: above + MissionControlCaptionLook.bandBelow + margin)
        let centreX = thumbnailMidX + lineOffset + covers.offset
        let top = baseline.map { barTop + $0 - above } ?? captionCentreY - full.height / 2
        let cut = min(max(((barTop + ceiling - top) * scale).rounded(.up) / scale, 0), above)
        return (LabelPlate(fill: fill, text: text, size: CGSize(width: full.width, height: full.height - cut),
                           baseline: above - cut),
                CGPoint(x: centreX - full.width / 2, y: top + cut))
    }
}

/// A label drawn from a caption strip, for the overlay: the strip, the part of it behind the label, the name drawn
/// over it and how they are laid out.
struct StripFace: Equatable {

    /// In points from the label's top-left, y down; and how far down the strip the label starts.
    struct Layout: Equatable {
        let size: CGSize
        let nameFrame: CGRect
        var cut: CGFloat = 0
    }

    let strip: CGImage
    /// The part of the strip behind the label, in unit coordinates from its top-left.
    let crop: CGRect
    let name: CGImage
    let layout: Layout

    /// `crop` as a layer's `contentsRect` has it, from the image's bottom-left on macOS.
    var contentsRect: CGRect {
        CGRect(x: crop.minX, y: 1 - crop.maxY, width: crop.width, height: crop.height)
    }

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

/// The names drawn over strips, each rendered once in a text style at a scale, and the native captions' ink.
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
    private var inks: [InkKey: Ink] = [:]

    /// A native caption's ink: its width, and how far right of the middle of its advance its middle lies.
    struct Ink {
        let width: CGFloat
        let offset: CGFloat
    }

    mutating func image(for name: String, style: CaptionStrip.TextStyle, scale: CGFloat) -> NameImage? {
        let key = Key(text: name, style: style, scale: scale)
        if let image = images[key] { return image }
        guard let image = NameImage.render(name, style: style, scale: scale) else { return nil }
        if images.count >= Self.limit { images = [:] }
        images[key] = image
        return image
    }

    mutating func ink(of text: String, style: CaptionStrip.TextStyle) -> Ink {
        let key = InkKey(text: text, fontSize: style.fontSize)
        if let ink = inks[key] { return ink }
        let ink = Ink(width: MissionControlCaptionLook.inkBounds(of: text, size: style.fontSize).width,
                      offset: MissionControlCaptionLook.inkOffset(of: text, size: style.fontSize))
        if inks.count >= Self.limit { inks = [:] }
        inks[key] = ink
        return ink
    }
}
