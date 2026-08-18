import Foundation
import AppKit
import CoreImage

/// Draws a caption cue into an image the compositor can stamp onto a frame.
///
/// Rasterizing is far too expensive to do per frame, so callers cache the
/// result — one image per cue (per spoken word for the karaoke style), reused
/// across every frame that cue is on screen.
enum CaptionRenderer {

    /// Captions never run wider than this fraction of the frame, which also
    /// keeps them clear of the action buttons down the right edge of TikTok
    /// and Reels.
    static let maxWidthFraction: CGFloat = 0.80

    /// Renders `cue` at a size suited to `renderSize`. `activeWordIndex` tints
    /// one word for styles that follow the speech.
    static func rasterize(cue: CaptionCue,
                          activeWordIndex: Int?,
                          style: CaptionStyle,
                          renderSize: CGSize) -> CIImage? {
        let spec = style.spec
        let fontSize = max(12, (min(renderSize.width, renderSize.height) * spec.sizeFactor).rounded())
        let text = attributedText(for: cue, activeWordIndex: activeWordIndex,
                                  spec: spec, fontSize: fontSize)
        guard text.length > 0 else { return nil }

        let padding = CGSize(width: (fontSize * spec.boxPaddingFraction.width).rounded(),
                             height: (fontSize * spec.boxPaddingFraction.height).rounded())
        // Room for the outline and shadow, which spill outside the glyph bounds.
        let bleed = (fontSize * (0.25 + spec.strokeFraction)).rounded()
        let maxTextWidth = max(40, renderSize.width * maxWidthFraction - 2 * (padding.width + bleed))

        let measured = text.boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = CGSize(width: min(maxTextWidth, ceil(measured.width)),
                              height: ceil(measured.height))
        guard textSize.width > 0, textSize.height > 0 else { return nil }

        let canvas = CGSize(width: textSize.width + 2 * (padding.width + bleed),
                            height: textSize.height + 2 * (padding.height + bleed))
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Flip into top-left origin so text lays out the way AppKit expects and
        // the resulting bitmap still reads right way up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let previous = NSGraphicsContext.current
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.current = previous }

        if let boxColor = spec.boxColor {
            let box = CGRect(x: bleed, y: bleed,
                             width: canvas.width - 2 * bleed,
                             height: canvas.height - 2 * bleed)
            let radius = min(fontSize * spec.boxCornerFraction, box.height / 2)
            context.setFillColor(boxColor.cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        text.draw(with: CGRect(x: padding.width + bleed, y: padding.height + bleed,
                               width: textSize.width, height: textSize.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])

        return context.makeImage().map(CIImage.init(cgImage:))
    }

    /// Bottom-left origin (Core Image space) for a caption of `size`.
    ///
    /// Portrait clips sit the block a third of the way up so it clears the
    /// caption and button furniture the social apps draw along the bottom;
    /// landscape clips sit just above the lower edge like normal subtitles.
    static func origin(forCaptionSize size: CGSize, renderSize: CGSize) -> CGPoint {
        let x = ((renderSize.width - size.width) / 2).rounded()
        let isPortrait = renderSize.height > renderSize.width
        let y = isPortrait
            ? (renderSize.height * 0.33 - size.height / 2).rounded()
            : (renderSize.height * 0.08).rounded()
        return CGPoint(x: max(0, x), y: min(max(0, y), max(0, renderSize.height - size.height)))
    }

    // MARK: Text

    private static func attributedText(for cue: CaptionCue,
                                       activeWordIndex: Int?,
                                       spec: CaptionStyleSpec,
                                       fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        var base: [NSAttributedString.Key: Any] = [
            .font: spec.font(ofSize: fontSize),
            .foregroundColor: spec.textColor,
            .paragraphStyle: paragraph
        ]
        if let strokeColor = spec.strokeColor, spec.strokeFraction > 0 {
            base[.strokeColor] = strokeColor
            // Negative width strokes *and* fills; a positive one would hollow
            // the glyphs out.
            base[.strokeWidth] = -spec.strokeFraction * 100
        }
        if spec.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
            shadow.shadowBlurRadius = fontSize * 0.18
            shadow.shadowOffset = CGSize(width: 0, height: -fontSize * 0.05)
            base[.shadow] = shadow
        }

        let words = spokenWords(in: cue)
        guard !words.isEmpty else {
            let text = spec.uppercase ? cue.text.uppercased() : cue.text
            return NSAttributedString(string: text, attributes: base)
        }

        let result = NSMutableAttributedString()
        for (index, word) in words.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " ", attributes: base)) }
            var attributes = base
            if index == activeWordIndex {
                if let highlight = spec.highlightColor { attributes[.foregroundColor] = highlight }
                if spec.highlightScale != 1 {
                    attributes[.font] = spec.font(ofSize: (fontSize * spec.highlightScale).rounded())
                }
            }
            let text = spec.uppercase ? word.uppercased() : word
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// The cue's words as the renderer lays them out — matching the indices the
    /// compositor uses to pick the active one.
    static func spokenWords(in cue: CaptionCue) -> [String] {
        if let words = cue.words, !words.isEmpty { return words.map(\.text) }
        return cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
