import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import AppKit

// MARK: - Custom video compositor (background + padded screen + camera PiP)

/// AVFoundation invokes its media callbacks on queues it owns. These wrapped
/// objects are confined to those queues even though the framework types have
/// not adopted Swift's `Sendable` annotation.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

final class CueVideoCompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let bubbleShape: CameraBubbleShape
    let corner: CameraCorner
    let cameraPlacement: CameraPlacement?
    let padding: CGFloat
    let background: CanvasBackground
    let mirrorBase: Bool
    let mirrorOverlay: Bool
    let cameraBackground: CameraBackground
    let cameraHiddenRanges: [ClosedRange<Double>]
    let mouseActivity: MouseActivity?
    let cinematicEffects: Bool
    let drawCustomCursor: Bool
    /// Nil renders the classic landscape composition; a layout switches to
    /// Creative Mode's vertical framing.
    let creativeLayout: CreativeLayout?
    let cameraStyle: CameraStyle
    let cutoutPlacement: CameraPlacement?
    /// Which slice of the screen fills the vertical frame. Nil centres it.
    let screenRegion: ScreenRegion?
    /// Whether the base video track is the camera (a camera-only recording)
    /// rather than the screen.
    let baseIsCamera: Bool
    /// Sorted, non-overlapping cues to burn in. Empty renders no captions.
    let captionCues: [CaptionCue]
    let captionStyle: CaptionStyle?

    init(timeRange: CMTimeRange,
         screenTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID,
         bubbleShape: CameraBubbleShape,
         corner: CameraCorner,
         cameraPlacement: CameraPlacement? = nil,
         padding: CGFloat,
         background: CanvasBackground,
         mirrorBase: Bool,
         mirrorOverlay: Bool,
         cameraBackground: CameraBackground = .none,
         cameraHiddenRanges: [ClosedRange<Double>] = [],
         mouseActivity: MouseActivity? = nil,
         cinematicEffects: Bool = false,
         drawCustomCursor: Bool = false,
         creativeLayout: CreativeLayout? = nil,
         cameraStyle: CameraStyle = .bubble,
         cutoutPlacement: CameraPlacement? = nil,
         screenRegion: ScreenRegion? = nil,
         baseIsCamera: Bool = false,
         captionCues: [CaptionCue] = [],
         captionStyle: CaptionStyle? = nil) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.bubbleShape = bubbleShape
        self.corner = corner
        self.cameraPlacement = cameraPlacement
        self.padding = padding
        self.background = background
        self.mirrorBase = mirrorBase
        self.mirrorOverlay = mirrorOverlay
        self.cameraBackground = cameraBackground
        self.cameraHiddenRanges = cameraHiddenRanges
        self.mouseActivity = mouseActivity
        self.cinematicEffects = cinematicEffects
        self.drawCustomCursor = drawCustomCursor
        self.creativeLayout = creativeLayout
        self.cameraStyle = cameraStyle
        self.cutoutPlacement = cutoutPlacement
        self.screenRegion = screenRegion
        self.baseIsCamera = baseIsCamera
        self.captionCues = captionCues
        self.captionStyle = captionStyle
        var ids = [NSNumber(value: screenTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

final class CueVideoCompositor: NSObject, AVVideoCompositing {

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "com.max.Cue.Compositor")
    private var maskCache: [String: CIImage] = [:]
    private var backgroundCache: [String: CIImage] = [:]
    private var captionCache: [String: CIImage] = [:]
    private lazy var pointerImage = Self.makePointerImage()

    /// Camera background compositing. Frames are processed serially on
    /// `renderQueue`, so a single matte (reused Vision request) is safe.
    private let matte = CameraMatte(quality: .balanced)

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)]
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { request.finish(with: RecordingError.compositionFailed("compositor gone")); return }
                guard let instruction = request.videoCompositionInstruction as? CueVideoCompositorInstruction,
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: RecordingError.compositionFailed("no output buffer"))
                    return
                }
                let size = request.renderContext.size
                var result = self.background(instruction.background, size: size)
                let nowSeconds = request.compositionTime.seconds

                if let layout = instruction.creativeLayout {
                    result = self.renderCreative(layout: layout, instruction: instruction,
                                                 request: request, renderSize: size,
                                                 at: nowSeconds, over: result)
                } else {
                    result = self.renderClassic(instruction: instruction, request: request,
                                                renderSize: size, at: nowSeconds, over: result)
                }

                if let style = instruction.captionStyle, !instruction.captionCues.isEmpty,
                   let caption = self.caption(cues: instruction.captionCues, style: style,
                                              at: nowSeconds, renderSize: size) {
                    result = caption.composited(over: result)
                }

                self.ciContext.render(result, to: output)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    // MARK: Render paths

    /// The landscape composition: canvas, padded screen card, camera bubble.
    private func renderClassic(instruction: CueVideoCompositorInstruction,
                               request: AVAsynchronousVideoCompositionRequest,
                               renderSize size: CGSize, at nowSeconds: Double,
                               over background: CIImage) -> CIImage {
        var result = background

        if let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID) {
            let image = self.screenImage(screenBuffer, instruction: instruction, at: nowSeconds)
            if instruction.background.isVisible {
                result = self.composeScreenWithPadding(image, padding: instruction.padding,
                                                       renderSize: size, over: result)
            } else {
                result = image.scaledToFill(size).composited(over: result)
            }
        }

        let cameraHidden = instruction.cameraHiddenRanges.contains { $0.contains(nowSeconds) }
        if instruction.cameraTrackID != kCMPersistentTrackID_Invalid, !cameraHidden,
           let cameraBuffer = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
            // Composite the chosen background first (segmentation runs in
            // the source buffer's own orientation), THEN mirror, so the
            // cutout and the picture stay aligned.
            var camera = self.matte.composite(cameraBuffer, background: instruction.cameraBackground)
            if instruction.mirrorOverlay { camera = camera.oriented(.upMirrored) }
            let bubble = self.makeBubble(camera, shape: instruction.bubbleShape,
                                         corner: instruction.corner,
                                         placement: instruction.cameraPlacement, renderSize: size)
            result = bubble.composited(over: result)
        }
        return result
    }

    /// The vertical composition used by Creative Mode: the screen is reframed
    /// for a 9:16 canvas and the person is cut out of the camera rather than
    /// boxed into a bubble.
    private func renderCreative(layout requestedLayout: CreativeLayout,
                                instruction: CueVideoCompositorInstruction,
                                request: AVAsynchronousVideoCompositionRequest,
                                renderSize size: CGSize, at nowSeconds: Double,
                                over background: CIImage) -> CIImage {
        var result = background

        // A camera-only clip has no separate camera track — its base video IS
        // the camera, so the person is cut out of that instead.
        let hasScreenTrack = !instruction.baseIsCamera
        let hasCameraTrack = instruction.baseIsCamera
            || instruction.cameraTrackID != kCMPersistentTrackID_Invalid

        // "Just me" needs a camera. Without one it would render an empty frame,
        // so show the screen rather than shipping a blank video.
        var layout = requestedLayout
        if layout == .personOnly && !hasCameraTrack { layout = .screenFill }

        // Hiding the camera takes the person away, never the whole picture.
        // When the person is all there is, fall back to the screen for that
        // stretch; when there's no screen either, keep them on frame — a blank
        // run in the finished video is worse than a control that looks ignored.
        let hiddenNow = instruction.cameraHiddenRanges.contains { $0.contains(nowSeconds) }
        let personHidden = hiddenNow && (layout != .personOnly || hasScreenTrack)
        let showsScreen = layout != .personOnly || personHidden

        if showsScreen, hasScreenTrack,
           let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID) {
            let image = self.screenImage(screenBuffer, instruction: instruction, at: nowSeconds)
            switch layout {
            case .stacked:
                let margin = max(size.width * 0.03, instruction.padding * size.width)
                let zone = CGRect(x: margin, y: size.height * 0.45,
                                  width: size.width - 2 * margin,
                                  height: size.height * 0.55 - margin)
                result = self.screenCard(image, in: zone, renderSize: size,
                                         cornerFraction: 0.03, shadow: true, over: result)
            case .screenFill, .personOnly:
                // Fill the tall frame with the chosen slice of the screen,
                // defaulting to the middle of it.
                result = image.cropped(to: instruction.screenRegion)
                    .scaledToFill(size).composited(over: result)
            }
        }

        let cameraBuffer = instruction.baseIsCamera
            ? request.sourceFrame(byTrackID: instruction.screenTrackID)
            : (instruction.cameraTrackID != kCMPersistentTrackID_Invalid
               ? request.sourceFrame(byTrackID: instruction.cameraTrackID) : nil)

        if !personHidden, let cameraBuffer {
            let mirrored = instruction.baseIsCamera ? instruction.mirrorBase : instruction.mirrorOverlay
            var person: CIImage?

            if instruction.cameraStyle == .cutout {
                // Segmentation dominates the frame budget, so soften the edge at
                // the mask's own resolution and let neighbouring frames share a
                // mask. Nil means nobody was found — draw nothing rather than
                // stamping down the opaque rectangle the cut-out exists to avoid.
                if var camera = self.matte.cutout(cameraBuffer, featherSigma: 1.5,
                                                  time: nowSeconds,
                                                  maskReuseWindow: Self.maskReuseWindow) {
                    if mirrored { camera = camera.oriented(.upMirrored) }
                    person = self.makeCutout(camera, layout: layout,
                                             placement: instruction.cutoutPlacement, renderSize: size)
                }
            } else {
                var camera = self.matte.composite(cameraBuffer,
                                                  background: instruction.cameraBackground,
                                                  featherSigma: 1.5, time: nowSeconds,
                                                  maskReuseWindow: Self.maskReuseWindow)
                if mirrored { camera = camera.oriented(.upMirrored) }
                person = self.makeBubble(camera, shape: instruction.bubbleShape,
                                         corner: instruction.corner,
                                         placement: instruction.cameraPlacement, renderSize: size)
            }

            if let person { result = person.composited(over: result) }
        }
        return result
    }

    /// Reuse a mask only for frames closer together than a 30 fps frame. Sitting
    /// just under the interval keeps 30 fps deterministic (never reused) while
    /// 60 fps halves its segmentation work.
    private static let maskReuseWindow = 0.9 / 30.0

    /// The screen frame with mirroring and pointer effects already applied.
    private func screenImage(_ buffer: CVPixelBuffer,
                             instruction: CueVideoCompositorInstruction,
                             at nowSeconds: Double) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer)
        if instruction.mirrorBase { image = image.oriented(.upMirrored) }
        if (instruction.cinematicEffects || instruction.drawCustomCursor),
           let activity = instruction.mouseActivity {
            image = applyCinematicEffects(to: image, activity: activity,
                                          at: nowSeconds,
                                          cinematicEffects: instruction.cinematicEffects,
                                          drawCustomCursor: instruction.drawCustomCursor)
        }
        return image
    }

    // MARK: Background

    private func background(_ background: CanvasBackground, size: CGSize) -> CIImage {
        let key = "\(background.rawValue)-\(Int(size.width))x\(Int(size.height))"
        if let cached = backgroundCache[key] { return cached }

        if let assetName = background.assetName,
           let artwork = artwork(named: assetName, size: size) {
            backgroundCache[key] = artwork
            return artwork
        }

        // If an artwork asset is unexpectedly unavailable, keep the recording
        // polished with the standard midnight gradient instead of rendering black.
        guard let stops = background.gradient ?? (background.isVisible ? CanvasBackground.midnight.gradient : nil) else {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        }
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: size.width / 2, y: 0)
        filter.color0 = CIColor(red: stops.bottom.0, green: stops.bottom.1, blue: stops.bottom.2)
        filter.point1 = CGPoint(x: size.width / 2, y: size.height)
        filter.color1 = CIColor(red: stops.top.0, green: stops.top.1, blue: stops.top.2)
        let image = (filter.outputImage ?? CIImage(color: .black))
            .cropped(to: CGRect(origin: .zero, size: size))
        backgroundCache[key] = image
        return image
    }

    private func artwork(named name: String, size: CGSize) -> CIImage? {
        guard let image = NSImage(named: name) else { return nil }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        return CIImage(cgImage: cgImage).scaledToFill(size)
    }

    // MARK: Padded screen (rounded + shadow)

    private func composeScreenWithPadding(_ screen: CIImage, padding: CGFloat,
                                          renderSize: CGSize, over background: CIImage) -> CIImage {
        let target = max(0.5, 1 - 2 * padding)
        let zone = CGRect(x: renderSize.width * (1 - target) / 2,
                          y: renderSize.height * (1 - target) / 2,
                          width: renderSize.width * target,
                          height: renderSize.height * target)
        // With no padding (a pure aspect-fit fill) the screen sits flush — no
        // rounded card or shadow, just the screen on the gradient. With padding
        // it becomes a floating, rounded, shadowed card.
        let flush = padding <= 0.015
        return screenCard(screen, in: zone, renderSize: renderSize,
                          cornerFraction: flush ? nil : 0.018, shadow: !flush, over: background)
    }

    /// Aspect-FITs the screen inside `zone` and composites it: when the source
    /// aspect differs from the canvas the whole window stays visible, with
    /// background (never black) filling the remaining space. `cornerFraction`
    /// (of the card's width) rounds the card; nil leaves it flush.
    private func screenCard(_ screen: CIImage, in zone: CGRect, renderSize: CGSize,
                            cornerFraction: CGFloat?, shadow: Bool,
                            over background: CIImage) -> CIImage {
        guard zone.width > 0, zone.height > 0 else { return background }
        let ext = screen.extent
        let sAspect = ext.height > 0 ? ext.width / ext.height : (zone.width / max(1, zone.height))
        var sw = zone.width
        var sh = sw / sAspect
        if sh > zone.height { sh = zone.height; sw = sh * sAspect }
        sw = sw.rounded()
        sh = sh.rounded()
        guard sw > 0, sh > 0 else { return background }
        let ox = (zone.midX - sw / 2).rounded()
        let oy = (zone.midY - sh / 2).rounded()

        let scaled = screen.scaledToFill(CGSize(width: sw, height: sh))

        guard let cornerFraction else {
            let flush = scaled.cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh))
                .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            return flush.composited(over: background)
        }

        let radius = max(8, sw * cornerFraction)
        let mask = roundedMask(width: sw, height: sh, radius: radius)

        let rounded = maskedImage(scaled, mask: mask, size: CGSize(width: sw, height: sh))
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))

        guard shadow else { return rounded.composited(over: background) }

        // Soft drop shadow behind the screen.
        let shadowShape = maskedImage(
            CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                .cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh)),
            mask: mask, size: CGSize(width: sw, height: sh)
        )
        .transformed(by: CGAffineTransform(translationX: ox, y: oy - renderSize.height * 0.006))
        .applyingGaussianBlur(sigma: max(10, renderSize.width * 0.010))
        .cropped(to: CGRect(origin: .zero, size: renderSize))

        return rounded.composited(over: shadowShape.composited(over: background))
    }

    // MARK: Cinematic pointer effects

    private func applyCinematicEffects(to source: CIImage, activity: MouseActivity,
                                       at seconds: Double, cinematicEffects: Bool,
                                       drawCustomCursor: Bool) -> CIImage {
        var image = source
        if cinematicEffects,
           let click = activity.clicks.last(where: { seconds >= $0.t && seconds - $0.t <= 0.72 }) {
            image = addClickRipple(to: image, click: click, age: seconds - click.t)
        }
        if drawCustomCursor, let position = smoothedPosition(in: activity.moves, at: seconds) {
            image = addPointer(to: image, position: position)
        }
        if cinematicEffects,
           let click = activity.clicks.last(where: { seconds >= $0.t && seconds - $0.t <= 2.2 }) {
            image = autoZoom(image, toward: click, age: seconds - click.t)
        }
        return image
    }

    private func autoZoom(_ image: CIImage, toward click: MouseSample, age: Double) -> CIImage {
        let progress: CGFloat
        if age < 0.34 {
            progress = smoothStep(CGFloat(age / 0.34))
        } else if age < 1.45 {
            progress = 1
        } else {
            progress = 1 - smoothStep(CGFloat((age - 1.45) / 0.75))
        }
        guard progress > 0.001 else { return image }

        let zoom = 1 + 0.30 * progress
        let extent = image.extent
        let cropWidth = extent.width / zoom
        let cropHeight = extent.height / zoom
        // Ease the focal point from frame center toward the click so zoom entry
        // never snaps, then clamp the crop to keep every output pixel valid.
        let clickX = extent.minX + extent.width * CGFloat(min(max(click.x, 0), 1))
        let clickY = extent.minY + extent.height * (1 - CGFloat(min(max(click.y, 0), 1)))
        let focusX = extent.midX + (clickX - extent.midX) * progress
        let focusY = extent.midY + (clickY - extent.midY) * progress
        let minX = min(max(focusX - cropWidth / 2, extent.minX), extent.maxX - cropWidth)
        let minY = min(max(focusY - cropHeight / 2, extent.minY), extent.maxY - cropHeight)
        let crop = CGRect(x: minX, y: minY, width: cropWidth, height: cropHeight)
        return image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .cropped(to: CGRect(origin: .zero, size: extent.size))
    }

    private func addClickRipple(to image: CIImage, click: MouseSample, age: Double) -> CIImage {
        let extent = image.extent
        let center = CGPoint(
            x: extent.minX + extent.width * CGFloat(min(max(click.x, 0), 1)),
            y: extent.minY + extent.height * (1 - CGFloat(min(max(click.y, 0), 1)))
        )
        let p = CGFloat(min(max(age / 0.72, 0), 1))
        let radius = extent.width * (0.010 + 0.026 * smoothStep(p))
        let thickness = max(3, extent.width * 0.0025)
        let outer = radialDisk(center: center, radius: radius + thickness, extent: extent)
        let inner = radialDisk(center: center, radius: max(0, radius - thickness), extent: extent)
        let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: inner
        ]).cropped(to: extent)
        let color = CIImage(color: CIColor(red: 0.04, green: 0.52, blue: 1,
                                           alpha: Double(0.9 * (1 - p))))
            .cropped(to: extent)
        return color.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: ring
        ]).cropped(to: extent)
    }

    private func radialDisk(center: CGPoint, radius: CGFloat, extent: CGRect) -> CIImage {
        let filter = CIFilter.radialGradient()
        filter.center = center
        filter.radius0 = Float(max(0, radius - 1.5))
        filter.radius1 = max(filter.radius0 + 1, Float(radius))
        filter.color0 = CIColor.white
        filter.color1 = CIColor.clear
        return (filter.outputImage ?? CIImage.empty()).cropped(to: extent)
    }

    private func smoothedPosition(in samples: [MouseSample], at seconds: Double) -> MouseSample? {
        guard let first = samples.first else { return nil }
        guard samples.count > 1, seconds > first.t else { return first }
        guard let last = samples.last else { return first }
        guard seconds < last.t else { return last }

        var low = 0
        var high = samples.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if samples[mid].t <= seconds { low = mid } else { high = mid }
        }
        let before = samples[low]
        let after = samples[high]
        let span = max(0.0001, after.t - before.t)
        let p = Double(smoothStep(CGFloat((seconds - before.t) / span)))
        return MouseSample(t: seconds,
                           x: before.x + (after.x - before.x) * p,
                           y: before.y + (after.y - before.y) * p)
    }

    private func addPointer(to image: CIImage, position: MouseSample) -> CIImage {
        let extent = image.extent
        let targetSize = max(28, extent.width * 0.013)
        let scale = targetSize / max(1, pointerImage.extent.width)
        let tipX = extent.minX + extent.width * CGFloat(min(max(position.x, 0), 1))
        let tipY = extent.minY + extent.height * (1 - CGFloat(min(max(position.y, 0), 1)))
        let pointer = pointerImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tipX - 4 * scale,
                                               y: tipY - 60 * scale))
        return pointer.composited(over: image).cropped(to: extent)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func makePointerImage() -> CIImage {
        let width = 64
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage.empty()
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4, y: 60))
        path.addLine(to: CGPoint(x: 4, y: 10))
        path.addLine(to: CGPoint(x: 18, y: 23))
        path.addLine(to: CGPoint(x: 27, y: 4))
        path.addLine(to: CGPoint(x: 38, y: 9))
        path.addLine(to: CGPoint(x: 29, y: 28))
        path.addLine(to: CGPoint(x: 48, y: 28))
        path.closeSubpath()
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(4)
        context.setStrokeColor(CGColor(gray: 0.05, alpha: 0.95))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.drawPath(using: .fillStroke)
        return context.makeImage().map(CIImage.init(cgImage:)) ?? CIImage.empty()
    }

    // MARK: Camera bubble

    private func makeBubble(_ camera: CIImage, shape: CameraBubbleShape,
                            corner: CameraCorner, placement: CameraPlacement?,
                            renderSize: CGSize) -> CIImage {
        let diameter: CGFloat = {
            if let placement {
                let frac = CGFloat(min(max(placement.size, 0.05), 0.9))
                return max(80, (renderSize.width * frac)).rounded()
            }
            return max(renderSize.width * 0.22, 180).rounded()
        }()
        let extent = camera.extent
        let side = min(extent.width, extent.height)
        let cropRect = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
        let squared = camera
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        let scale = diameter / side
        let scaled = squared.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: diameter, height: diameter))

        let mask = roundedMask(width: diameter, height: diameter, radius: shape.cornerRadius(for: diameter))
        let masked = maskedImage(scaled, mask: mask, size: CGSize(width: diameter, height: diameter))

        let x: CGFloat
        let y: CGFloat
        if let placement {
            // Normalized center (top-left origin) → CI space (bottom-left origin),
            // clamped so the bubble stays fully on-frame.
            let cx = CGFloat(min(max(placement.centerX, 0), 1)) * renderSize.width
            let cyTop = CGFloat(min(max(placement.centerY, 0), 1)) * renderSize.height
            let rawX = cx - diameter / 2
            let rawY = (renderSize.height - cyTop) - diameter / 2     // flip Y
            x = min(max(rawX, 0), max(0, renderSize.width - diameter)).rounded()
            y = min(max(rawY, 0), max(0, renderSize.height - diameter)).rounded()
        } else {
            let margin = max(renderSize.width * 0.025, 24)
            switch corner {
            case .bottomLeft:  x = margin;                              y = margin
            case .bottomRight: x = renderSize.width - diameter - margin; y = margin
            case .topLeft:     x = margin;                              y = renderSize.height - diameter - margin
            case .topRight:    x = renderSize.width - diameter - margin; y = renderSize.height - diameter - margin
            }
        }
        return masked.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    // MARK: Person cut-out

    /// Places the segmented person on the frame at full extent — no square crop
    /// and no rounded mask, so there's no visible container around them. Sized
    /// by height (a bubble's width-relative size makes no sense on a tall
    /// frame), and deliberately not clamped on-frame: letting the person run
    /// past the bottom edge is what produces the waist-up framing shorts use.
    private func makeCutout(_ camera: CIImage, layout: CreativeLayout,
                            placement: CameraPlacement?, renderSize: CGSize) -> CIImage {
        let placement = placement ?? layout.defaultCutoutPlacement
        let extent = camera.extent
        guard extent.width > 0, extent.height > 0 else { return CIImage.empty() }

        let targetHeight = renderSize.height * CGFloat(min(max(placement.size, 0.15), 1.4))
        let scale = targetHeight / extent.height
        let scaled = camera.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Normalized center (top-left origin) → CI space (bottom-left origin).
        let cx = CGFloat(min(max(placement.centerX, -0.25), 1.25)) * renderSize.width
        let cyTop = CGFloat(min(max(placement.centerY, -0.25), 1.4)) * renderSize.height
        let x = cx - scaled.extent.width / 2
        let y = (renderSize.height - cyTop) - scaled.extent.height / 2

        return scaled
            .transformed(by: CGAffineTransform(translationX: (x - scaled.extent.minX).rounded(),
                                               y: (y - scaled.extent.minY).rounded()))
            .cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    // MARK: Captions

    /// The caption image for this instant, positioned on the frame. Rasterized
    /// images are cached — drawing text per frame would cost far more than the
    /// rest of the composition put together.
    private func caption(cues: [CaptionCue], style: CaptionStyle,
                         at seconds: Double, renderSize: CGSize) -> CIImage? {
        guard let index = Self.cueIndex(in: cues, at: seconds) else { return nil }
        let cue = cues[index]
        let activeWord = style.highlightsSpokenWord
            ? Self.activeWordIndex(in: cue, at: seconds)
            : nil

        let key = "\(index)-\(activeWord ?? -1)-\(style.rawValue)-\(Int(renderSize.width))x\(Int(renderSize.height))"
        let image: CIImage
        if let cached = captionCache[key] {
            image = cached
        } else {
            guard let rendered = CaptionRenderer.rasterize(cue: cue, activeWordIndex: activeWord,
                                                           style: style, renderSize: renderSize)
            else { return nil }
            // Cues are visited in order, so an occasional full clear keeps a
            // long word-by-word track from piling up bitmaps.
            if captionCache.count > 200 { captionCache.removeAll(keepingCapacity: true) }
            captionCache[key] = rendered
            image = rendered
        }

        let origin = CaptionRenderer.origin(forCaptionSize: image.extent.size, renderSize: renderSize)
        return image.transformed(by: CGAffineTransform(translationX: origin.x - image.extent.minX,
                                                       y: origin.y - image.extent.minY))
    }

    /// Binary search over sorted, non-overlapping cues.
    private static func cueIndex(in cues: [CaptionCue], at seconds: Double) -> Int? {
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if seconds < cues[mid].start {
                high = mid - 1
            } else if seconds >= cues[mid].end {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// Which word of the cue is being spoken. Between words the previous one
    /// stays lit rather than the highlight flickering off.
    private static func activeWordIndex(in cue: CaptionCue, at seconds: Double) -> Int? {
        let words = cue.words ?? CaptionCueBuilder.interpolatedWords(in: cue)
        guard !words.isEmpty else { return nil }
        if let index = words.firstIndex(where: { seconds >= $0.start && seconds < $0.end }) {
            return index
        }
        return words.lastIndex(where: { seconds >= $0.start }) ?? 0
    }

    // MARK: Helpers

    private func maskedImage(_ image: CIImage, mask: CIImage, size: CGSize) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func roundedMask(width: CGFloat, height: CGFloat, radius: CGFloat) -> CIImage {
        let key = "\(Int(width))x\(Int(height))-\(Int(radius))"
        if let cached = maskCache[key] { return cached }
        let w = Int(width), h = Int(height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        let mask = ctx.makeImage().map { CIImage(cgImage: $0) }
            ?? CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        maskCache[key] = mask
        return mask
    }
}

private extension CIImage {
    /// Crops to a normalized region expressed with a top-left origin, which is
    /// how the picker and the plan describe it — Core Image works bottom-up, so
    /// the y axis flips here.
    func cropped(to region: ScreenRegion?) -> CIImage {
        guard let region, !region.isWholeScreen else { return self }
        let ex = extent
        guard ex.width > 0, ex.height > 0 else { return self }
        let rect = CGRect(x: ex.minX + region.x * ex.width,
                          y: ex.minY + (1 - region.y - region.height) * ex.height,
                          width: region.width * ex.width,
                          height: region.height * ex.height)
        let clamped = rect.intersection(ex)
        return clamped.isNull || clamped.isEmpty ? self : cropped(to: clamped)
    }

    func scaledToFill(_ size: CGSize) -> CIImage {
        let ex = extent
        guard ex.width > 0, ex.height > 0 else { return self }
        let scale = max(size.width / ex.width, size.height / ex.height)
        let scaled = transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2
        let dy = (scaled.extent.height - size.height) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: -scaled.extent.minX - dx,
                                               y: -scaled.extent.minY - dy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}

// MARK: - Composer

enum VideoComposer {

    struct Output {
        let url: URL
        let size: CGSize
        /// Audio-only sidecar (`audio.m4a`) for transcription, when the clip has
        /// audio. Small and locked to the final timeline; uploaded alongside the
        /// video so the backend transcribes audio, not the whole movie.
        let audioURL: URL?
    }

    /// A built composition, plus everything needed to re-derive its video
    /// composition. The editor holds one of these and swaps only the video
    /// composition as the user drags — far cheaper than rebuilding tracks.
    struct BuiltComposition {
        let composition: AVMutableComposition
        let contentDuration: CMTime
        let renderSize: CGSize
        let fps: Int
        let screenTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID
        /// True when the base video track is the camera (a camera-only clip).
        let baseIsCamera: Bool
        let sourceAspect: CGFloat
    }

    /// How the canvas behind the screen is filled. Derived in one place so the
    /// render size and the compositor instruction can't disagree about it.
    private struct CanvasLayout {
        let needsCanvas: Bool
        let fill: CanvasBackground
        let padding: CGFloat
    }

    private static func canvasLayout(for plan: CompositionPlan, baseIsCamera: Bool,
                                     sourceAspect: CGFloat) -> CanvasLayout {
        // Creative Mode always has a visible canvas: it shows around the
        // stacked screen card and behind a person standing on their own.
        if plan.isCreative {
            return CanvasLayout(needsCanvas: true,
                                fill: plan.background.isVisible ? plan.background : .midnight,
                                padding: CGFloat(plan.padding))
        }
        // Target aspect is the requested ratio (e.g. 16:9), or the source's own
        // when "follow screen". When the source doesn't match the target — OR a
        // background is chosen — render onto a gradient canvas and aspect-FIT
        // the screen onto it, so the clip never letterboxes to black in a player
        // and the screen is never cropped. Camera-only clips keep their frame.
        let targetAspect = baseIsCamera ? sourceAspect : (plan.aspectRatio.map { CGFloat($0) } ?? sourceAspect)
        let aspectMismatch = abs(targetAspect - sourceAspect) > 0.01
        let needsCanvas = !baseIsCamera && (plan.background.isVisible || aspectMismatch)
        // Fill with the chosen background, or a default midnight gradient when
        // the screen just needs to be fit to the target aspect.
        let fill: CanvasBackground = plan.background.isVisible ? plan.background : (needsCanvas ? .midnight : .none)
        // Respect the chosen padding exactly when a background is set (0 = the
        // screen grows to the frame edge, gradient only fills aspect-ratio gaps).
        // A pure aspect-fit (no background chosen) never adds margin.
        let padding: CGFloat = plan.background.isVisible ? CGFloat(plan.padding) : 0
        return CanvasLayout(needsCanvas: needsCanvas, fill: fill, padding: padding)
    }

    /// Renders a plan to `outputURL`, plus the audio sidecar.
    static func compose(plan: CompositionPlan,
                        screenURL: URL?,
                        cameraURL: URL?,
                        mouseActivity: MouseActivity? = nil,
                        captions: [CaptionCue] = [],
                        outputURL: URL) async throws -> Output {
        let built = try await buildComposition(plan: plan, screenURL: screenURL, cameraURL: cameraURL,
                                               workdir: outputURL.deletingLastPathComponent())
        let videoComposition = makeVideoComposition(for: built, plan: plan,
                                                    mouseActivity: mouseActivity, captions: captions)
        return try await export(built: built, videoComposition: videoComposition, to: outputURL)
    }

    /// Builds the track layout for a plan: screen, camera overlay and audio,
    /// with the lead-in and paused spans spliced out. Everything that depends
    /// on the raw media lives here; everything the editor can change live lives
    /// in `makeVideoComposition`.
    ///
    /// `previewScale` shrinks the render size for a live preview.
    static func buildComposition(plan: CompositionPlan,
                                 screenURL: URL?,
                                 cameraURL: URL?,
                                 previewScale: CGFloat = 1,
                                 workdir: URL) async throws -> BuiltComposition {

        guard let baseVideoURL = screenURL ?? cameraURL else {
            throw RecordingError.compositionFailed("no video to compose")
        }
        let composition = AVMutableComposition()
        let baseAsset = AVURLAsset(url: baseVideoURL)

        guard let baseTrack = try await baseAsset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.compositionFailed("no video track")
        }
        let baseDuration = try await baseAsset.load(.duration)
        let naturalSize = try await baseTrack.load(.naturalSize)
        let cameraIsBase = (screenURL == nil)
        let fps = plan.fps ?? 30
        let screenPauseSpans = plan.screenPauseSpans
        let cameraPauseSpans = plan.cameraPauseSpans

        let screenAspect = naturalSize.height > 0 ? naturalSize.width / naturalSize.height : 16.0 / 9.0
        let canvas = canvasLayout(for: plan, baseIsCamera: cameraIsBase, sourceAspect: screenAspect)
        var renderSize: CGSize
        if plan.isCreative {
            // Short-form video is 1080×1920 regardless of what was captured;
            // the screen is reframed to fit rather than the frame following it.
            renderSize = CreativeLayout.renderSize
        } else if canvas.needsCanvas {
            let targetAspect = cameraIsBase ? screenAspect : (plan.aspectRatio.map { CGFloat($0) } ?? screenAspect)
            renderSize = Self.renderSize(forSource: naturalSize, aspect: targetAspect,
                                         padding: Double(canvas.padding))
        } else {
            renderSize = evenSize(naturalSize)
        }
        if previewScale != 1 {
            renderSize = evenSize(CGSize(width: renderSize.width * previewScale,
                                         height: renderSize.height * previewScale))
        }

        // Trim the countdown/warm-up lead-in off the front of every stream, so
        // the clip begins exactly at content-start with all streams rolling.
        let lead = min(CMTime(seconds: max(0, plan.leadTrim ?? 0), preferredTimescale: 600), baseDuration)

        // The base records continuously through pauses; cut those spans out (in
        // the base file's own timeline) so the clip has no dead air. Screen and
        // camera-only bases use their respective spans; the base audio below is
        // cut with the *same* spans so it stays locked to the picture.
        let baseSpans = cameraIsBase ? cameraPauseSpans : screenPauseSpans
        let baseVideoDuration = (try? await baseTrack.load(.timeRange).duration) ?? baseDuration

        guard let screenCompTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: 1) else {
            throw RecordingError.compositionFailed("video track alloc")
        }
        let contentDuration = try Self.insertExcised(
            baseTrack, into: screenCompTrack,
            from: CMTimeGetSeconds(lead), to: CMTimeGetSeconds(baseVideoDuration),
            spans: baseSpans, at: .zero)

        // Camera overlay (only when there's a separate screen base)
        var cameraTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if screenURL != nil, let cameraURL,
           FileManager.default.fileExists(atPath: cameraURL.path) {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let camComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2) {
                let camDuration = try await cameraAsset.load(.duration)
                // Where the camera began relative to the screen (original
                // timeline), then shifted onto the trimmed timeline.
                let camStartOnBase = plan.cameraStartOffset
                    ?? max(0, CMTimeGetSeconds(baseDuration) - CMTimeGetSeconds(camDuration))
                let camCompStart = camStartOnBase - CMTimeGetSeconds(lead)
                var camSourceStart = CMTime.zero
                var camInsertAt = CMTime.zero
                if camCompStart >= 0 {
                    // Camera started after content-start → small gap is correct.
                    camInsertAt = CMTime(seconds: camCompStart, preferredTimescale: 600)
                } else {
                    // Camera was already rolling at content-start → trim its head.
                    camSourceStart = CMTime(seconds: -camCompStart, preferredTimescale: 600)
                }
                // The camera rolls continuously through pauses, so cut the paused
                // spans out of the source and splice the remaining chunks back
                // together — matching the screen track (cut with the same spans)
                // so the PiP stays locked instead of freezing or drifting.
                let camEnd = try Self.insertExcised(
                    cameraTrack, into: camComp,
                    from: CMTimeGetSeconds(camSourceStart), to: CMTimeGetSeconds(camDuration),
                    spans: cameraPauseSpans, at: camInsertAt, limit: contentDuration)
                if camEnd > camInsertAt { cameraTrackID = camComp.trackID }
            }
        }

        // Audio comes straight from the base file, cut with the SAME lead-in and
        // paused spans as the base video so it stays perfectly locked, and capped
        // to the video length so there's no audio-only tail.
        try await addAudio(from: baseAsset, lead: lead, spans: baseSpans, limit: contentDuration,
                           composition: composition, workdir: workdir)

        return BuiltComposition(composition: composition,
                                contentDuration: contentDuration,
                                renderSize: renderSize,
                                fps: fps,
                                screenTrackID: screenCompTrack.trackID,
                                cameraTrackID: cameraTrackID,
                                baseIsCamera: cameraIsBase,
                                sourceAspect: screenAspect)
    }

    /// Everything the editor can change without touching the tracks: layout,
    /// placement, mirroring, captions and pointer effects. Cheap enough to
    /// rebuild on every drag.
    static func makeVideoComposition(for built: BuiltComposition,
                                     plan: CompositionPlan,
                                     mouseActivity: MouseActivity? = nil,
                                     captions: [CaptionCue] = []) -> AVMutableVideoComposition {
        let canvas = canvasLayout(for: plan, baseIsCamera: built.baseIsCamera,
                                  sourceAspect: built.sourceAspect)
        let burnsCaptions = plan.burnsCaptions && !captions.isEmpty

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CueVideoCompositor.self
        // Render the final at the captured rate (60 when chosen) rather than a
        // fixed 30 — otherwise the extra frames captured at 60 fps are dropped here.
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, built.fps)))
        videoComposition.renderSize = built.renderSize
        videoComposition.instructions = [
            CueVideoCompositorInstruction(
                timeRange: CMTimeRange(start: .zero, duration: built.contentDuration),
                screenTrackID: built.screenTrackID,
                cameraTrackID: built.cameraTrackID,
                bubbleShape: plan.bubbleShape,
                corner: plan.corner,
                cameraPlacement: plan.cameraPlacement,
                padding: canvas.padding,
                // No canvas behind a classic camera-only clip; Creative Mode
                // always wants one, since the person is cut out of their own.
                background: (built.baseIsCamera && !plan.isCreative) ? .none : canvas.fill,
                mirrorBase: plan.mirrored && built.baseIsCamera,
                mirrorOverlay: plan.mirrored && !built.baseIsCamera,
                cameraBackground: plan.cameraBackground,
                cameraHiddenRanges: plan.cameraHiddenRanges,
                mouseActivity: built.baseIsCamera ? nil : mouseActivity,
                cinematicEffects: !built.baseIsCamera && (plan.cinematicEffectsEnabled ?? false),
                drawCustomCursor: !built.baseIsCamera && (plan.sourceShowsCursor == false),
                creativeLayout: plan.creativeLayout,
                cameraStyle: plan.effectiveCameraStyle,
                cutoutPlacement: plan.cutoutPlacement ?? plan.creativeLayout?.defaultCutoutPlacement,
                screenRegion: plan.screenRegion,
                baseIsCamera: built.baseIsCamera,
                captionCues: burnsCaptions ? captions : [],
                captionStyle: burnsCaptions ? (plan.captionStyle ?? .boldOutline) : nil)
        ]
        return videoComposition
    }

    // MARK: Export

    private static func export(built: BuiltComposition,
                               videoComposition: AVMutableVideoComposition,
                               to outputURL: URL) async throws -> Output {
        let composition = built.composition
        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.compositionFailed("exporter unavailable")
        }
        export.videoComposition = videoComposition
        // Move MP4 metadata ahead of media data so browsers can begin playback
        // after fetching the head instead of waiting for the entire object.
        export.shouldOptimizeForNetworkUse = true
        do {
            try await export.export(to: outputURL, as: .mp4)
        } catch {
            throw RecordingError.compositionFailed(error.localizedDescription)
        }

        // Audio-only sidecar for transcription. Exporting the same composition
        // with the AppleM4A preset yields just the (already lead-trimmed,
        // pause-excised, mixed) audio as a small .m4a — so the backend can
        // transcribe audio instead of pulling the full video.
        var audioURL: URL?
        if !composition.tracks(withMediaType: .audio).isEmpty {
            let candidate = outputURL.deletingLastPathComponent().appendingPathComponent("audio.m4a")
            if (try? await exportAudio(composition: composition, to: candidate)) == true {
                audioURL = candidate
            }
        }

        return Output(url: outputURL, size: built.renderSize, audioURL: audioURL)
    }

    /// Exports the composition's audio track to a standalone `.m4a` (AAC).
    private static func exportAudio(composition: AVComposition, to outputURL: URL) async throws -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: outputURL, as: .m4a)
        return true
    }

    /// Returns the sub-ranges of `[start, end]` that remain after removing
    /// `spans` — used to splice paused time out of the continuous camera track.
    private static func subtractSpans(from start: Double, to end: Double,
                                      spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard end > start else { return [] }
        guard !spans.isEmpty else { return [start...end] }
        var result: [ClosedRange<Double>] = []
        var cursor = start
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = max(start, span.lowerBound)
            let upper = min(end, span.upperBound)
            if upper <= cursor { continue }                  // entirely behind the cursor
            if lower > cursor { result.append(cursor...lower) } // active chunk before this pause
            cursor = max(cursor, upper)
        }
        if cursor < end { result.append(cursor...end) }
        return result
    }

    /// Encoders want even dimensions.
    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (size.width / 2).rounded() * 2),
               height: max(2, (size.height / 2).rounded() * 2))
    }

    /// Canvas frame sized so the source fits at `1 - 2·padding` of a frame with
    /// the given `aspect` (w/h), preserving source resolution.
    private static func renderSize(forSource natural: CGSize, aspect: CGFloat, padding: Double) -> CGSize {
        let even = evenSize
        guard natural.width > 0, natural.height > 0, aspect > 0 else { return even(natural) }
        let target = max(0.5, 1 - 2 * CGFloat(padding))
        let sAspect = natural.width / natural.height
        var cw: CGFloat
        var ch: CGFloat
        if sAspect >= aspect {
            cw = natural.width / target
            ch = cw / aspect
        } else {
            ch = natural.height / target
            cw = ch * aspect
        }
        let maxDim: CGFloat = 3840
        let longest = max(cw, ch)
        if longest > maxDim { let r = maxDim / longest; cw *= r; ch *= r }
        return even(CGSize(width: cw, height: ch))
    }

    /// Inserts one audio track into the composition. One source track passes
    /// through; two or more are mixed (sync-preserving) via AVAssetReader. The
    /// front `lead` seconds and the paused `spans` are cut out — exactly as the
    /// base video — so the audio stays locked to the picture.
    private static func addAudio(from asset: AVURLAsset, lead: CMTime, spans: [ClosedRange<Double>],
                                 limit: CMTime, composition: AVMutableComposition, workdir: URL) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty,
              let audioComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 3) else {
            return
        }
        func insert(_ track: AVAssetTrack) async {
            let dur = (try? await track.load(.timeRange).duration) ?? .zero
            _ = try? insertExcised(track, into: audioComp,
                                   from: CMTimeGetSeconds(lead), to: CMTimeGetSeconds(dur),
                                   spans: spans, at: .zero, limit: limit)
        }

        if audioTracks.count == 1 {
            await insert(audioTracks[0])
            return
        }

        // Mix system + mic into one track, preserving each track's timing.
        let mixedURL = workdir.appendingPathComponent("mixed.caf")
        try await AudioMixer.mixTracks(asset: asset, tracks: audioTracks, to: mixedURL)
        let mixedAsset = AVURLAsset(url: mixedURL)
        if let mixedTrack = try await mixedAsset.loadTracks(withMediaType: .audio).first {
            await insert(mixedTrack)
        }
    }

    /// Splices `source[startSec...endSec]` into `comp` starting at `at`, cutting
    /// out `spans` (all in the source's own seconds) and butting the kept chunks
    /// together. Optionally stops once the composition reaches `limit`. Returns
    /// the end position in the composition.
    @discardableResult
    private static func insertExcised(_ source: AVAssetTrack, into comp: AVMutableCompositionTrack,
                                      from startSec: Double, to endSec: Double,
                                      spans: [ClosedRange<Double>], at start: CMTime,
                                      limit: CMTime? = nil) throws -> CMTime {
        var pos = start
        for range in subtractSpans(from: startSec, to: endSec, spans: spans) {
            var chunk = range.upperBound - range.lowerBound
            if let limit {
                let remaining = CMTimeGetSeconds(limit - pos)
                if remaining <= 0 { break }
                chunk = min(chunk, remaining)
            }
            if chunk <= 0 { continue }
            let src = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                  duration: CMTime(seconds: chunk, preferredTimescale: 600))
            try comp.insertTimeRange(src, of: source, at: pos)
            pos = pos + CMTime(seconds: chunk, preferredTimescale: 600)
        }
        return pos
    }
}

// MARK: - Sync-preserving track mixer

enum AudioMixer {

    /// Mixes the given audio tracks of `asset` into a single PCM `.caf` using
    /// `AVAssetReaderAudioMixOutput`, which respects each track's presentation
    /// timing — so the mix stays locked to the video.
    static func mixTracks(asset: AVAsset, tracks: [AVAssetTrack], to outputURL: URL) async throws {
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
        guard reader.canAdd(mixOutput) else { throw RecordingError.compositionFailed("audio mix output") }
        reader.add(mixOutput)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .caf)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw RecordingError.compositionFailed("audio writer input") }
        writer.add(writerInput)

        guard reader.startReading() else { throw RecordingError.compositionFailed("audio reader start") }
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.compositionFailed("audio writer start")
        }
        writer.startSession(atSourceTime: .zero)

        let q = DispatchQueue(label: "com.max.Cue.AudioMixer")
        let sendableInput = UncheckedSendable(value: writerInput)
        let sendableOutput = UncheckedSendable(value: mixOutput)
        let sendableWriter = UncheckedSendable(value: writer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sendableInput.value.requestMediaDataWhenReady(on: q) {
                while sendableInput.value.isReadyForMoreMediaData {
                    if let sample = sendableOutput.value.copyNextSampleBuffer() {
                        sendableInput.value.append(sample)
                    } else {
                        sendableInput.value.markAsFinished()
                        sendableWriter.value.finishWriting { continuation.resume() }
                        return
                    }
                }
            }
        }
    }
}
