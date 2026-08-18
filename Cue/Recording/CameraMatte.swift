import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import CoreVideo

/// Person-segmentation + background compositing for the camera, shared by the
/// live preview pipeline (`CameraEngine`) and the offline compositor
/// (`CueVideoCompositor`). One instance is used from a single serial queue —
/// the Vision request is reused across frames, so don't share an instance
/// across threads; share the type and make one per consumer.
final class CameraMatte {

    private let request = VNGeneratePersonSegmentationRequest()
    /// Last mask (at its native low resolution) and the composition time it was
    /// generated for, used to skip re-segmenting near-identical frames.
    private var cachedMask: CIImage?
    private var cachedMaskTime: Double?

    /// `quality`: use `.fast` for the live preview (cheap, runs continuously)
    /// and `.balanced`/`.accurate` for the final export.
    init(quality: VNGeneratePersonSegmentationRequest.QualityLevel) {
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Returns the camera frame with its background replaced per `background`,
    /// in the pixel buffer's own coordinate space. `.none` (or a segmentation
    /// failure) returns the untouched frame so callers degrade gracefully.
    ///
    /// - Parameters:
    ///   - featherSigma: softens the mask edge so a cut-out person doesn't have
    ///     a razor-sharp outline. Applied at the mask's own low resolution, so
    ///     it costs almost nothing.
    ///   - time: composition time of this frame, needed for `maskReuseWindow`.
    ///   - maskReuseWindow: reuse the previous mask for frames closer together
    ///     than this. Segmentation is the most expensive step in the frame, and
    ///     a person doesn't move far in a 60th of a second.
    func composite(_ pixelBuffer: CVPixelBuffer,
                   background: CameraBackground,
                   featherSigma: Double = 0,
                   time: Double? = nil,
                   maskReuseWindow: Double = 0) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard background.removesBackground,
              let mask = personMask(for: pixelBuffer,
                                    matching: image.extent,
                                    featherSigma: featherSigma,
                                    time: time,
                                    reuseWindow: maskReuseWindow) else { return image }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = mask
        blend.backgroundImage = backdrop(for: background, source: image)
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }

    /// The person alone, with everything behind them removed — or nil when
    /// nobody could be found in the frame.
    ///
    /// Separate from `composite` because the two want opposite fallbacks: a
    /// bubble can safely show the raw frame when segmentation comes up empty,
    /// but the cut-out cannot — drawing an un-segmented frame there would stamp
    /// down exactly the opaque rectangle the cut-out exists to get rid of.
    func cutout(_ pixelBuffer: CVPixelBuffer,
                featherSigma: Double = 0,
                time: Double? = nil,
                maskReuseWindow: Double = 0) -> CIImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let mask = personMask(for: pixelBuffer,
                                    matching: image.extent,
                                    featherSigma: featherSigma,
                                    time: time,
                                    reuseWindow: maskReuseWindow) else { return nil }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = mask
        blend.backgroundImage = CIImage.empty()
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: Mask

    private func personMask(for pixelBuffer: CVPixelBuffer,
                            matching extent: CGRect,
                            featherSigma: Double,
                            time: Double?,
                            reuseWindow: Double) -> CIImage? {
        var mask: CIImage?
        if reuseWindow > 0, let time, let cachedMask, let cachedMaskTime,
           abs(time - cachedMaskTime) < reuseWindow {
            mask = cachedMask
        } else {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            if (try? handler.perform([request])) != nil,
               let maskBuffer = request.results?.first?.pixelBuffer {
                var generated = CIImage(cvPixelBuffer: maskBuffer)
                // Blur at the mask's native size — after the stretch below this
                // becomes a few soft pixels at full resolution.
                if featherSigma > 0 {
                    generated = generated.clampedToExtent()
                        .applyingGaussianBlur(sigma: featherSigma)
                        .cropped(to: generated.extent)
                }
                mask = generated
                cachedMask = generated
                cachedMaskTime = time
            }
        }
        guard let mask, mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        // The mask is lower-resolution; stretch it to line up with the frame.
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    // MARK: Backdrops

    /// What sits behind the person for each mode (transparent → nothing).
    private func backdrop(for background: CameraBackground, source: CIImage) -> CIImage {
        switch background {
        case .none, .transparent:
            return CIImage.empty()
        case .blur:
            return source.clampedToExtent()
                .applyingGaussianBlur(sigma: max(8, source.extent.height * 0.04))
                .cropped(to: source.extent)
        case .gradient:
            return Self.gradient(in: source.extent)
        case .color:
            return CIImage(color: Self.solidColor).cropped(to: source.extent)
        }
    }

    /// A clean dark slate (not pure black) for the solid backdrop.
    private static let solidColor = CIColor(red: 0.12, green: 0.13, blue: 0.17)

    /// A tasteful vertical indigo→azure gradient for the gradient backdrop.
    private static func gradient(in rect: CGRect) -> CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: rect.midX, y: rect.minY)
        filter.color0 = CIColor(red: 0.13, green: 0.16, blue: 0.40)   // deep indigo (bottom)
        filter.point1 = CGPoint(x: rect.midX, y: rect.maxY)
        filter.color1 = CIColor(red: 0.26, green: 0.52, blue: 0.96)   // azure (top)
        return (filter.outputImage ?? CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.3)))
            .cropped(to: rect)
    }
}
